import PlumeCore
import _Concurrency

// The Model protocol the @Model macro satisfies. Class-bound (models are
// `final class`) so `save()` can populate `id` and dirty tracking can snapshot
// instances. Used only as a generic constraint (`some Model` / `T: Model`),
// never as `any Model` — that would be an existential, forbidden in Embedded.
public protocol Model: AnyObject {
    /// The static schema descriptor (table, columns, PK). Source of truth = type.
    static var schema: TableSchema { get }

    /// Decode an instance from a positionally-ordered row (schema column order).
    init(row: Row)

    /// Column values in `schema.columns` order (used to build INSERT/UPDATE).
    func columnValues() -> [SQLValue]

    /// Snapshot the current column values as "clean" (called after save/load).
    func takeSnapshot()

    /// Indices (into `schema.columns`) whose value differs from the snapshot — the
    /// columns an UPDATE must touch. All columns if never snapshotted.
    func changedColumnIndices() -> [Int]

    /// Inject this instance's id (and FK names) into its has-many relation handles.
    /// Called after load/save (the embedded-safe substitute for enclosing-self).
    func refreshRelations()

    /// Set auto-managed `createdAt`/`updatedAt` (if the model declares them) from
    /// `ORMClock`. Called by `save()` — `creating` is true on INSERT.
    func touchTimestamps(creating: Bool)

    /// Synchronous field validations (default none). Override with a `static let`.
    static var validations: [Validation<Self>] { get }

    /// Asynchronous validations like uniqueness (default none).
    static var asyncValidations: [AsyncValidation<Self>] { get }

    // NOTE: there is deliberately NO `var id` protocol requirement. Each model declares
    // its own `id` at its real type (`Int`, `Int64`, or `UUID`), and the framework works
    // through `primaryKeyValue` / `setDatabaseGeneratedID` generically. A hardcoded
    // `var id: Int` here would SHADOW a stored `var id: Int64`/`UUID`, silently reading 0.

    /// The primary key's value as a bound SQL parameter. Defaults to the integer `id`;
    /// @Model overrides it for a custom primary key (e.g. `sqlText(email)`).
    var primaryKeyValue: SQLValue { get }

    /// The primary key column's type, so a child's `@BelongsTo` FK column can mirror it.
    /// Defaults to `.integer`; @Model overrides it for a UUID/String key.
    static var primaryKeyColumnType: ColumnType { get }

    /// The SQL column name of the auto-managed `createdAt` (honoring an @Column rename),
    /// or nil if the model has none. `upsert` uses it to preserve creation time. @Model
    /// emits it; the default is nil.
    static var createdAtColumn: String? { get }

    /// Whether this instance represents an already-persisted row. Integer `id`
    /// models default to `id != 0`; generated non-integer primary-key models track
    /// this explicitly so UUID/string keys can exist before INSERT.
    var isPersisted: Bool { get }

    /// Mark this model as loaded/saved. Generated non-integer primary-key models
    /// flip their explicit persistence state here.
    func markPersisted()

    /// Mark this model as new. Used by JSON decoding, where a payload may carry a
    /// caller-supplied UUID/string primary key but still needs INSERT semantics.
    func markNewRecord()

    /// True when the database, rather than app code, supplies the primary key on
    /// INSERT. The default integer `id` convention sets this to true.
    static var databaseGeneratedPrimaryKey: Bool { get }

    /// Store the database-generated primary key (SQLite/D1 rowid or Postgres RETURNING)
    /// after INSERT. @Model emits this for an `Int`/`Int64` `id` PK (an `Int64` PK keeps
    /// the full 64-bit value); non-generated PKs use the default no-op.
    func setDatabaseGeneratedID(_ id: Int64)

    /// A predicate every query starts from (nil = none). `SoftDeletable` uses this to
    /// hide soft-deleted rows; bypass per-query with `.unscoped()` / `withTrashed()`.
    static var defaultScope: Predicate<Self>? { get }

    // Lifecycle callbacks (no-ops by default) — hooks around persistence. `willSave`
    // runs after validation and before the INSERT/UPDATE (mutate fields here, e.g.
    // derive a slug); a thrown error aborts the write and propagates.
    func willSave() async throws
    func didSave() async throws
    func willDelete() async throws
    func didDelete() async throws
}

extension Model {
    public static var validations: [Validation<Self>] { [] }
    public static var asyncValidations: [AsyncValidation<Self>] { [] }

    public static var defaultScope: Predicate<Self>? { nil }

    public func willSave() async throws {}
    public func didSave() async throws {}
    public func willDelete() async throws {}
    public func didDelete() async throws {}

    /// Default primary-key value. @Model always emits an override (integer `id`, UUID, …);
    /// this fallback exists only to satisfy the protocol for a hand-written conformer.
    public var primaryKeyValue: SQLValue { .integer(0) }

    /// Default PK column type: integer. @Model emits an override for a UUID/String key.
    public static var primaryKeyColumnType: ColumnType { .integer }

    public static var createdAtColumn: String? { nil }

    /// Default (overridden by @Model): a hand-written conformer is treated as unpersisted.
    public var isPersisted: Bool { false }
    public func markPersisted() {}
    public func markNewRecord() {}
    public static var databaseGeneratedPrimaryKey: Bool { false }
    public func setDatabaseGeneratedID(_ id: Int64) {}   // no-op for non-generated (UUID/String) PKs

    /// The primary-key column name, taken from the schema (default `id`).
    public static var primaryKeyColumn: String {
        for column in schema.columns where column.isPrimaryKey { return column.name }
        return "id"
    }

    /// Run synchronous field validations.
    public func validate() -> [ValidationError] {
        var errors: [ValidationError] = []
        for validation in Self.validations {
            if let message = validation.check(self) {
                errors.append(ValidationError(field: validation.field, message: message))
            }
        }
        return errors
    }

    /// Run synchronous validations then asynchronous ones (uniqueness, …).
    public func validate(in db: Database) async throws -> [ValidationError] {
        var errors = validate()
        for validation in Self.asyncValidations {
            if let message = try await validation.check(self, db) {
                errors.append(ValidationError(field: validation.field, message: message))
            }
        }
        return errors
    }

    /// Whether the synchronous field validations pass.
    public var isValid: Bool { validate().isEmpty }
}

/// Byte-wise `SQLValue` equality for dirty tracking. `.text` is compared as UTF-8
/// bytes — never `String ==`, which fails to link under embedded wasm.
public func sqlValueBytesEqual(_ a: SQLValue, _ b: SQLValue) -> Bool {
    switch (a, b) {
    case (.null, .null): return true
    case (.integer(let x), .integer(let y)): return x == y
    case (.double(let x), .double(let y)): return x == y
    case (.text(let x), .text(let y)): return Array(x.utf8) == Array(y.utf8)
    case (.blob(let x), .blob(let y)): return x == y
    default: return false
    }
}

// MARK: - The @Model macro
//
// A member macro. It runs in the host compiler plugin (PlumeMacros) but emits
// only Embedded-clean Swift: the schema descriptor, a positional row codec, a
// memberwise initializer, and (later steps) typed columns + relationship handles.
@attached(member, names:
    named(schema), named(init), named(columnValues),
    named(_snapshot), named(takeSnapshot), named(changedColumnIndices),
    named(refreshRelations), named(touchTimestamps), named(primaryKeyValue),
    named(_persisted), named(isPersisted), named(markPersisted), named(markNewRecord),
    named(databaseGeneratedPrimaryKey),
    arbitrary  // the typed `static let <column>` query-builder columns
)
public macro Model(table: String = "", primaryKey: String = "id") = #externalMacro(module: "PlumeMacros", type: "ModelMacro")

// `@Column("db_name")` — override the SQL column name for a stored property whose
// Swift name differs from the database column. Read by `@Model` at expansion;
// emits no code of its own (a marker). Enables database-first adoption where the
// existing schema's column names don't match Swift conventions
// (`var displayName` ⇄ `display_name`, `var createdAt` ⇄ `created_at`).
@attached(peer)
public macro Column(_ name: String) = #externalMacro(module: "PlumeMacros", type: "ColumnMacro")
