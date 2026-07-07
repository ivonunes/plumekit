import PlumeCore
import _Concurrency

// Relationships as property wrappers, so a model gets `$author` / `$comments`
// handles. Loading is EXPLICIT and async (`try await post.$comments.load(in:db)`)
// — no property access silently fires a query. Concrete generic value types only,
// no existentials. Embedded constraints shape this: keypaths are forbidden under
// embedded wasm, so the enclosing-self wrapper subscript is out (HasMany gets its
// owner id injected by @Model's `refreshRelations()` instead), and eager loading
// uses closures, not `\.$comments` keypaths.

/// `@BelongsTo var author: User` → an `author_id` column (managed by @Model) plus a
/// `$author` handle. The wrapper stores the FK as a raw `SQLValue`, so it works for an
/// integer, UUID, or String parent key; `.load` fetches.
@propertyWrapper
public struct BelongsTo<Related: Model>: @unchecked Sendable {
    /// The raw foreign-key value (any primary-key type). `.integer(0)` means "unset".
    public var key: SQLValue
    public var cached: Related?

    public init() { self.key = .integer(0); self.cached = nil }
    public init(wrappedValue: Related?) {
        self.key = wrappedValue?.primaryKeyValue ?? .integer(0); self.cached = wrappedValue
    }
    public init(id: Int) { self.key = sqlInt(id); self.cached = nil }
    public init(key: SQLValue) { self.key = key; self.cached = nil }

    // `@BelongsTo(foreignKey: "user_id")` / `@BelongsTo(foreignKey: "owner_id",
    // nullable: true)` — the FK column name and nullability are read by the @Model macro
    // at expansion (database-first adoption: the FK column isn't `<name>ID`). At runtime
    // the wrapper still stores only the key, so these initializers just seed the default.
    public init(foreignKey: String) { self.key = .integer(0); self.cached = nil }
    public init(foreignKey: String, nullable: Bool) { self.key = .integer(0); self.cached = nil }
    public init(nullable: Bool) { self.key = .integer(0); self.cached = nil }

    /// The integer foreign key, for the common `Int`-PK parent (0 when unset or when the
    /// parent key isn't an integer — read `key` for a UUID/String parent). `Int` is 32-bit
    /// on the Wasm guest: use `id64` for an `Int64`-PK parent whose key may exceed 2^31.
    public var id: Int { if case .integer(let n) = key { return Int(truncatingIfNeeded: n) }; return 0 }

    /// The foreign key as a full-width `Int64`, for an `Int64`-PK parent (large D1 rowids
    /// stay faithful; `id` would truncate on the 32-bit guest). 0 when unset/non-integer.
    public var id64: Int64 { if case .integer(let n) = key { return n }; return 0 }

    /// The key to persist. Re-reads the cached parent so assigning a not-yet-saved
    /// parent and saving IT afterwards still writes the real id (not the stale 0
    /// captured at assignment).
    public var resolvedKey: SQLValue { cached?.primaryKeyValue ?? key }

    /// The related object if already loaded/assigned, else nil. Never auto-loads.
    public var wrappedValue: Related? {
        get { cached }
        // Assigning nil must CLEAR the key (a nullable FK then persists as NULL) — not
        // leave the previous key stale.
        set { cached = newValue; key = newValue?.primaryKeyValue ?? .integer(0) }
    }

    public var projectedValue: BelongsTo<Related> {
        get { self }
        set { self = newValue }
    }

    /// Fetch the related row (or return the cached one). One query.
    public func load(in db: Database) async throws -> Related? {
        if let cached { return cached }
        if case .null = key { return nil }
        if case .integer(0) = key { return nil }   // unset integer FK
        return try await Related.find(key, in: db)
    }
}

/// `@HasMany var comments: [Comment]` → a `$comments` handle keyed on the child's
/// foreign key. The owner's primary-key value + FK name are injected by @Model's
/// refreshRelations, so it works for an integer, UUID, or String owner key.
@propertyWrapper
public struct HasMany<Child: Model>: @unchecked Sendable {
    public var ownerKey: SQLValue
    public var foreignKey: String
    public var cached: [Child]?

    public init() { self.ownerKey = .integer(0); self.foreignKey = ""; self.cached = nil }
    // `@HasMany(foreignKey: "owner_id")` — the FK column name is read by @Model at
    // expansion and injected via refreshRelations, so this just seeds the default.
    public init(foreignKey: String) { self.ownerKey = .integer(0); self.foreignKey = ""; self.cached = nil }

    /// The integer owner key, for the common `Int`-PK owner (0 otherwise). Wraps rather
    /// than trapping on the 32-bit guest for a large `Int64` owner key (matches `BelongsTo.id`).
    public var ownerID: Int { if case .integer(let n) = ownerKey { return Int(truncatingIfNeeded: n) }; return 0 }

    /// Loaded children, or empty if not loaded. Never auto-loads.
    public var wrappedValue: [Child] { cached ?? [] }

    public var projectedValue: HasMany<Child> {
        get { self }
        set { self = newValue }
    }

    /// Fetch children where `<foreignKey> == ownerKey` (or return cached). One query.
    public func load(in db: Database) async throws -> [Child] {
        if let cached { return cached }
        return try await Child.where(Predicate(sql: foreignKey + " = ?", bindings: [ownerKey])).all(in: db)
    }
}

// MARK: - IN predicate (for batched eager loading)

extension Column where Value == Int {
    /// `col IN (?, ?, …)` — bound values, never interpolated.
    public func `in`(_ ids: [Int]) -> Predicate<Root> {
        if ids.isEmpty { return Predicate(sql: "0 = 1", bindings: []) }
        var sql = name + " IN ("
        var bindings: [SQLValue] = []
        var i = 0
        while i < ids.count {
            if i > 0 { sql += ", " }
            sql += "?"
            bindings.append(sqlInt(ids[i]))
            i += 1
        }
        sql += ")"
        return Predicate(sql: sql, bindings: bindings)
    }
}

// MARK: - Batched eager loading (no N+1, keypath-free)

/// Load a has-many relation for many owners in ONE child query, then group and
/// assign. Closures stand in for the (embedded-forbidden) keypaths: `childKey`
/// reads a child's FK, `assign` stores the grouped children on each owner.
///
/// Total queries = 1 (plus however the owners were fetched) — never N+1.
public func eagerLoad<Owner: Model, Child: Model>(
    _ owners: [Owner],
    foreignKey: String,
    childKey: (Child) -> SQLValue,
    assign: (Owner, [Child]) -> Void,
    in db: Database
) async throws {
    if owners.isEmpty { return }
    let keys = owners.map { $0.primaryKeyValue }             // any PK type
    var placeholders = ""
    for i in keys.indices { placeholders += i == 0 ? "?" : ", ?" }
    let children = try await Child.where(
        Predicate(sql: foreignKey + " IN (" + placeholders + ")", bindings: keys)).all(in: db)
    for owner in owners {
        let ownerKey = owner.primaryKeyValue
        var mine: [Child] = []
        for child in children where sqlKeyEqual(childKey(child), ownerKey) { mine.append(child) }
        assign(owner, mine)
    }
}

/// Key equality for grouping. Tolerates an integer/real tag mismatch (a backend may
/// return a numeric FK as `.double` while the owner re-encodes it as `.integer`) so
/// children don't silently fail to group; otherwise exact `SQLValue` equality.
private func sqlKeyEqual(_ a: SQLValue, _ b: SQLValue) -> Bool {
    switch (a, b) {
    case (.integer(let x), .integer(let y)): return x == y
    case (.integer(let x), .double(let y)), (.double(let y), .integer(let x)): return Double(x) == y
    case (.double(let x), .double(let y)): return x == y
    case (.text(let x), .text(let y)): return Array(x.utf8) == Array(y.utf8)   // byte-wise: String == doesn't link in the guest
    case (.blob(let x), .blob(let y)): return x == y
    case (.null, .null): return true
    default: return false
    }
}
