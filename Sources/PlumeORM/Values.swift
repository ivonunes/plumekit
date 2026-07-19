import PlumeCore

// Re-export the core SQL value type so a model file needs only `import PlumeORM` (the
// generated `[SQLValue]` resolves here).
public typealias SQLValue = PlumeCore.SQLValue
public typealias UUID = PlumeCore.UUID
/// Aliased so macro-generated members (the `preload<Relation>` helpers) can name
/// the type in a model file that imports only PlumeORM.
public typealias Database = PlumeCore.Database

// SQLValue constructors. The @Model encoder emits calls to these instead of
// naming `PlumeKit`'s enum cases directly: under Embedded Swift an enum case may
// only be used in a file that imports its module, and a model file imports only
// PlumeORM. These live in PlumeORM (which imports PlumeKit), so the cases are
// legal here and the generated code stays import-clean.
public func sqlInt(_ value: Int) -> SQLValue { .integer(Int64(value)) }
public func sqlInt(_ value: Int64) -> SQLValue { .integer(value) }
public func sqlUUID(_ value: UUID) -> SQLValue { .text(value.uuidString) }
public func sqlText(_ value: String) -> SQLValue { .text(value) }
public func sqlBool(_ value: Bool) -> SQLValue { .integer(value ? 1 : 0) }
public func sqlReal(_ value: Double) -> SQLValue { .double(value) }
public func sqlBlob(_ value: [UInt8]) -> SQLValue { .blob(value) }

// Optional constructors for NULLABLE columns: a `nil` Swift value becomes a real
// SQL NULL (not a 0/""/false). The @Model encoder emits these for `Optional` scalar
// properties so an adopted nullable column round-trips faithfully.
public func sqlIntOptional(_ value: Int?) -> SQLValue { value.map { sqlInt($0) } ?? .null }
public func sqlInt64Optional(_ value: Int64?) -> SQLValue { value.map { sqlInt($0) } ?? .null }
public func sqlUUIDOptional(_ value: UUID?) -> SQLValue { value.map { sqlUUID($0) } ?? .null }
public func sqlTextOptional(_ value: String?) -> SQLValue { value.map { sqlText($0) } ?? .null }
public func sqlBoolOptional(_ value: Bool?) -> SQLValue { value.map { sqlBool($0) } ?? .null }
public func sqlRealOptional(_ value: Double?) -> SQLValue { value.map { sqlReal($0) } ?? .null }
public func sqlBlobOptional(_ value: [UInt8]?) -> SQLValue { value.map { sqlBlob($0) } ?? .null }

// A `@BelongsTo` foreign key whose column is NULLABLE: the wrapper stores `0` to mean
// "no relation", which must persist as SQL NULL (ids start at 1, so 0 is never a real
// key). A non-nullable FK keeps using `sqlInt` directly.
public func sqlForeignKeyOptional(_ id: Int) -> SQLValue { id == 0 ? .null : sqlInt(id) }

/// The SQLValue form (relations store the FK as a raw key of any type). An unset
/// integer FK (0) persists as NULL for a nullable relation; other keys pass through.
public func sqlForeignKeyOptional(_ key: SQLValue) -> SQLValue {
    if case .integer(0) = key { return .null }
    return key
}
