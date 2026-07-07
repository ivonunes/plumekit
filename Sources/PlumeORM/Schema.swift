import PlumeCore

// The compile-time schema descriptor the @Model macro emits. The model's Swift
// type is the source of truth; this is its static, diff-able projection that
// migration tooling can diff. Names are ASCII protocol tokens — never compared
// with Unicode-aware `String ==` in the guest (those tables don't link there); SQL is
// built by byte/append, collation is delegated to the database.

public enum ColumnType: Sendable {
    case integer   // Int / Int64        → SQLValue.integer
    case uuid      // UUID               → SQLValue.text (canonical UUID)
    case text      // String             → SQLValue.text
    case real      // Double             → SQLValue.double
    case blob      // [UInt8]            → SQLValue.blob
    case boolean   // Bool (stored as 0/1 integer)
}

public struct ColumnSchema: Sendable {
    public let name: String
    public let type: ColumnType
    public let isPrimaryKey: Bool
    public let isNullable: Bool
    public let isDatabaseGenerated: Bool

    public init(
        name: String,
        type: ColumnType,
        isPrimaryKey: Bool = false,
        isNullable: Bool = false,
        isDatabaseGenerated: Bool? = nil
    ) {
        self.name = name
        self.type = type
        self.isPrimaryKey = isPrimaryKey
        self.isNullable = isNullable
        self.isDatabaseGenerated = isDatabaseGenerated ?? (isPrimaryKey && isConventionalIntegerID(name, type))
    }
}

private func isConventionalIntegerID(_ name: String, _ type: ColumnType) -> Bool {
    guard Array(name.utf8) == Array("id".utf8) else { return false }
    if case .integer = type { return true }
    return false
}

public struct TableSchema: Sendable {
    public let table: String
    public let columns: [ColumnSchema]

    public init(table: String, columns: [ColumnSchema]) {
        self.table = table
        self.columns = columns
    }

    /// Columns an INSERT supplies (excludes database-generated primary keys).
    public var insertableColumns: [ColumnSchema] {
        columns.filter { !$0.isDatabaseGenerated }
    }
}
