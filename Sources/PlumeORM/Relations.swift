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

    /// Whether the relation has been loaded (or assigned). An unloaded read of
    /// `wrappedValue` is nil — check this to tell "not loaded" from "no parent".
    public var isLoaded: Bool { if case .some = cached { return true }; return false }

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

    /// Whether the children have been loaded. An unloaded read of `wrappedValue`
    /// is `[]` — indistinguishable from "no children" — so check this (or use
    /// `load`/a preload helper) when the difference matters.
    public var isLoaded: Bool { if case .some = cached { return true }; return false }

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

// MARK: - Batched eager loading (no N+1, keypath-free)

#if !hasFeature(Embedded)
/// `eagerLoad` was pointed at a foreign-key column the child model doesn't have
/// (a typo, or an owner/child FK-name mismatch).
public enum EagerLoadError: Error, CustomStringConvertible {
    case unknownForeignKey(table: String, column: String)
    public var description: String {
        switch self {
        case .unknownForeignKey(let table, let column):
            return "eagerLoad: \(table) has no column named \(column)"
        }
    }
}
#endif

/// Load a has-many relation for many owners in ONE child query, then group and
/// assign. The child's FK value is read from its decoded row via the schema (no
/// closure needed); `assign` stands in for the (embedded-forbidden) keypath and
/// stores the grouped children on each owner. Prefer the typed helper @Model
/// generates per relation (`Post.preloadComments(posts)`) — it supplies the FK
/// name so a typo can't reach this.
///
/// Total queries = 1 (plus however the owners were fetched) — never N+1.
/// Grouping is one pass over the children (a map keyed by normalised FK bytes),
/// not owners × children.
public func eagerLoad<Owner: Model, Child: Model>(
    _ owners: [Owner],
    foreignKey: String,
    assign: (Owner, [Child]) -> Void,
    in db: Database? = nil
) async throws {
    let db = resolvedDatabase(db)
    if owners.isEmpty { return }
    var fkIndex = -1
    for (index, column) in Child.schema.columns.enumerated() where utf8Equal(column.name, foreignKey) {
        fkIndex = index
        break
    }
    guard fkIndex >= 0 else {
        // A misspelled FK is a programming error, but natively it must surface as a
        // catchable per-request error (a 500), not take down the whole server with
        // every in-flight request. The guest can't throw a helpful `any Error`, so
        // it traps there (single-request instances — nothing else is lost).
        #if hasFeature(Embedded)
        fatalError("eagerLoad: unknown foreign key column")
        #else
        throw EagerLoadError.unknownForeignKey(table: Child.schema.table, column: foreignKey)
        #endif
    }
    let keys = owners.map { $0.primaryKeyValue }             // any PK type
    var placeholders = ""
    for i in keys.indices { placeholders += i == 0 ? "?" : ", ?" }
    let children = try await Child.where(
        Predicate(sql: foreignKey + " IN (" + placeholders + ")", bindings: keys)).all(in: db)

    var grouped: [[UInt8]: [Child]] = [:]
    for child in children {
        grouped[normalizedKeyBytes(child.columnValues()[fkIndex]), default: []].append(child)
    }
    for owner in owners {
        assign(owner, grouped[normalizedKeyBytes(owner.primaryKeyValue)] ?? [])
    }
}

/// A `SQLValue` as grouping-key bytes. An integral `.double` folds onto `.integer`
/// (a backend may return a numeric FK as a real while the owner re-encodes it as an
/// integer), so children can't silently fail to group. Byte-wise — no `String ==`.
private func normalizedKeyBytes(_ value: SQLValue) -> [UInt8] {
    func integerBytes(_ n: Int64) -> [UInt8] {
        var out: [UInt8] = [1]
        var u = UInt64(bitPattern: n)
        for _ in 0..<8 { out.append(UInt8(truncatingIfNeeded: u)); u >>= 8 }
        return out
    }
    switch value {
    case .integer(let n): return integerBytes(n)
    case .double(let d):
        if let n = Int64(exactly: d) { return integerBytes(n) }
        var out: [UInt8] = [2]
        var u = d.bitPattern
        for _ in 0..<8 { out.append(UInt8(truncatingIfNeeded: u)); u >>= 8 }
        return out
    case .text(let s): return [3] + Array(s.utf8)
    case .blob(let b): return [4] + b
    case .null: return [5]
    }
}
