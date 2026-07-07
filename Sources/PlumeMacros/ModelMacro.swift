import Foundation
import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

// Code-generation plans (file scope so they get memberwise initializers).
private struct ColumnPlan {
    let constName: String    // identifier for the typed query `static let`
    let sqlName: String       // the SQL column name (may be overridden via @Column / foreignKey)
    let columnType: String
    let isPK: Bool
    let isNullable: Bool
    let isDatabaseGenerated: Bool
    let constType: String
    var typeExpr: String? = nil    // overrides `.columnType` in the schema (e.g. a FK's `Parent.primaryKeyColumnType`)
    let decode: (Int) -> String
    let encode: String
}
private struct HasManyPlan { let name: String; let foreignKey: String }
private struct InitParam { let decl: String; let assign: String }

// The @Model member macro. Reads the model class at COMPILE time (the Embedded
// substitute for runtime reflection) and emits static, Embedded-clean members:
// schema, a positional row codec, a memberwise init, dirty tracking, typed query
// columns, and relationship plumbing (FK columns for @BelongsTo; owner-id
// injection for @HasMany).
//
// Database-first adoption: every naming/typing convention is overridable so a model can
// conform to a PRE-EXISTING, externally-created schema —
//   • `@Model(table: "legacy_orders")`          — table name the pluralizer can't produce
//   • `@Column("display_name") var name`        — SQL column name ≠ Swift property name
//   • `@BelongsTo(foreignKey: "owner_id") ...`  — FK column name ≠ `<name>_id`
//   • `var quantity: Int?`                      — NULLABLE column (NULL ⇄ nil, not 0)
//   • `var createdAt: String?`                  — TEXT ISO-8601 timestamps (vs Int64 epoch)
//
// HOST code — full Swift is fine here; only the emitted STRINGS must be Embedded-clean.

public struct ModelMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],   // current MemberMacro requirement; unused (we add members, not conformances)
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let cls = declaration.as(ClassDeclSyntax.self) else {
            throw MacroError("@Model can only be applied to a final class")
        }
        let typeName = cls.name.text
        let table = tableOverride(from: node) ?? pluralize(snakeCaseIdentifier(typeName))
        let primaryKeyName = nodeStringArgument(node, label: "primaryKey") ?? "id"
        let ownerForeignKey = snakeCaseIdentifier(typeName) + "_id"   // FK other tables use to point here

        let fields = try storedFields(of: cls)
        guard fields.contains(where: { if case .scalar = $0.role { return $0.name == primaryKeyName } else { return false } }) else {
            if primaryKeyName == "id" {
                throw MacroError("@Model '\(typeName)' must declare `var id: Int` or `var id: UUID` (the primary key), or pass primaryKey:")
            }
            throw MacroError("@Model '\(typeName)' primaryKey '\(primaryKeyName)' must name a declared scalar property")
        }
        var hasDatabaseGeneratedId = false   // auto-increment integer `id` PK (excluded from init, set to 0)
        var databaseGeneratedKind: FieldKind = .int   // .int or .int64 — chooses the id write cast
        var hasTrackedPersistenceState = false

        // Columns (in declaration order) = scalars + belongs-to FKs. Has-many are
        // relations, not columns. Positional codec relies on this order.
        var columns: [ColumnPlan] = []
        var hasManys: [HasManyPlan] = []
        var initParams: [InitParam] = []
        var primaryKeyColumnType = "integer"   // the PK column type — a child FK mirrors it

        for field in fields {
            switch field.role {
            case .scalar(let kind, let optional):
                let name = field.name
                let col = field.columnName ?? snakeCaseIdentifier(name)
                let isPK = name == primaryKeyName
                if isPK, optional {
                    throw MacroError("@Model '\(typeName)': primary key '\(name)' must not be optional — declare it non-optional (e.g. `var \(name): \(kind.swiftType)`).")
                }
                if isPK { primaryKeyColumnType = kind.columnType }
                // Any integer PK auto-increments (matches SchemaBuilder rendering SERIAL /
                // AUTOINCREMENT for a non-"id" name), not just one literally named `id`.
                let isDatabaseGenerated = isPK && kind.isIntegerID
                if isDatabaseGenerated { hasDatabaseGeneratedId = true; databaseGeneratedKind = kind }
                if isPK && !isDatabaseGenerated { hasTrackedPersistenceState = true }
                let nullable = optional && !isPK
                columns.append(ColumnPlan(
                    constName: name, sqlName: col, columnType: kind.columnType, isPK: isPK,
                    isNullable: nullable, isDatabaseGenerated: isDatabaseGenerated, constType: kind.swiftType,
                    decode: { i in nullable
                        ? "self.\(name) = row.\(kind.rowAccessor)Optional(\(i))"
                        : "self.\(name) = row.\(kind.rowAccessor)(\(i))" },
                    encode: nullable ? kind.sqlValueOptional(field: name) : kind.sqlValue(field: name)))
                if !isDatabaseGenerated {   // a custom/app-generated PK is an init parameter
                    let typeStr = optional ? kind.swiftType + "?" : kind.swiftType
                    let decl: String
                    if let d = field.defaultExpr { decl = "\(name): \(typeStr) = \(d)" }
                    else if isPK && name == "id" && kind == .uuid { decl = "\(name): \(typeStr) = PlumeORM.UUID()" }
                    else if optional { decl = "\(name): \(typeStr) = nil" }
                    else { decl = "\(name): \(typeStr)" }
                    initParams.append(InitParam(decl: decl, assign: "self.\(name) = \(name)"))
                }
            case .belongsTo(let related, let fkOverride, let nullable):
                let name = field.name
                let fk = field.columnName ?? fkOverride ?? (snakeCaseIdentifier(name) + "_id")
                // The FK column mirrors the PARENT's primary-key type (integer for the
                // common case, text for a UUID/String parent) and stores the raw key, so
                // the relation works regardless of the parent's key type.
                columns.append(ColumnPlan(
                    constName: fk, sqlName: fk, columnType: "integer", isPK: false,
                    isNullable: nullable, isDatabaseGenerated: false, constType: "Int",
                    typeExpr: "\(related).primaryKeyColumnType",
                    decode: { "self.$\(name) = BelongsTo(key: row.value(\($0)))" },
                    encode: nullable ? "sqlForeignKeyOptional(self.$\(name).resolvedKey)" : "self.$\(name).resolvedKey"))
                initParams.append(InitParam(decl: "\(name): \(related)? = nil", assign: "self.\(name) = \(name)"))
            case .hasMany(_, let fkOverride):
                // A database-first child may name its FK column something other than
                // `<owner>_id` (via @BelongsTo(foreignKey:)); `@HasMany(foreignKey:)`
                // names it on this side so the reverse query hits the right column.
                hasManys.append(HasManyPlan(name: field.name, foreignKey: fkOverride ?? ownerForeignKey))
            }
        }

        // Reject two properties mapping to the same SQL column (e.g. a scalar `userId` and
        // a `@BelongsTo` both → `user_id`). Otherwise the schema/INSERT would list the column
        // twice and fail at runtime with no compile-time hint.
        var seenColumns: Set<String> = []
        for c in columns where !seenColumns.insert(c.sqlName).inserted {
            throw MacroError(
                "@Model '\(typeName)': duplicate column name '\(c.sqlName)' — two properties map to the same SQL column. Rename one or set @Column(\"…\").")
        }

        // 1. schema
        var columnDecls: [String] = []
        for c in columns {
            var opts = ""
            if c.isPK { opts += ", isPrimaryKey: true" }
            if c.isNullable { opts += ", isNullable: true" }
            if c.isDatabaseGenerated { opts += ", isDatabaseGenerated: true" }
            let typeExpr = c.typeExpr ?? ".\(c.columnType)"
            columnDecls.append("        ColumnSchema(name: \"\(c.sqlName)\", type: \(typeExpr)\(opts))")
        }
        let schema: DeclSyntax = """
        public static let schema = TableSchema(table: "\(raw: table)", columns: [
        \(raw: columnDecls.joined(separator: ",\n"))
            ])
        """

        // 2. positional row decode + refresh relations + snapshot
        var decodeLines: [String] = []
        for (i, c) in columns.enumerated() { decodeLines.append("        " + c.decode(i)) }
        let initRow: DeclSyntax = """
        public init(row: Row) {
        \(raw: decodeLines.joined(separator: "\n"))
                self.markPersisted()
                self.refreshRelations()
                self.takeSnapshot()
        }
        """

        // 3. column values
        let valueExprs = columns.map { $0.encode }
        let columnValues: DeclSyntax = """
        public func columnValues() -> [SQLValue] {
            [\(raw: valueExprs.joined(separator: ", "))]
        }
        """

        // 4. memberwise init (auto-id PK is set to 0; a custom PK is a parameter)
        var assigns: [String] = []
        // Initialize the stored PK to 0. For an `Int64` PK the literal must be typed
        // `Int64(0)`, else it binds to the protocol's default computed `var id: Int` (a
        // no-op) and leaves the stored property uninitialized.
        if hasDatabaseGeneratedId {
            assigns.append(databaseGeneratedKind == .int64
                ? "        self.\(primaryKeyName) = Int64(0)" : "        self.\(primaryKeyName) = 0")
        }
        for p in initParams { assigns.append("        " + p.assign) }
        let memberwiseInit: DeclSyntax = """
        public init(\(raw: initParams.map { $0.decl }.joined(separator: ", "))) {
        \(raw: assigns.joined(separator: "\n"))
        }
        """

        // 5. dirty tracking
        let snapshot: DeclSyntax = "public var _snapshot: [SQLValue]? = nil"
        let takeSnapshot: DeclSyntax = "public func takeSnapshot() { self._snapshot = self.columnValues() }"
        let changed: DeclSyntax = """
        public func changedColumnIndices() -> [Int] {
            let current = self.columnValues()
            guard let snap = self._snapshot else {
                var all: [Int] = []; var i = 0
                while i < current.count { all.append(i); i += 1 }
                return all
            }
            var changed: [Int] = []; var i = 0
            while i < current.count {
                if !sqlValueBytesEqual(current[i], snap[i]) { changed.append(i) }
                i += 1
            }
            return changed
        }
        """

        // 5b. persistence state. The integer `id` convention can use `id != 0`;
        // UUID/string/custom PKs need explicit state because their key exists
        // before INSERT.
        let persistedStorage: DeclSyntax = "public var _persisted: Bool = false"
        let isPersistedDecl: DeclSyntax = hasTrackedPersistenceState
            ? "public var isPersisted: Bool { self._persisted }"
            : "public var isPersisted: Bool { self.\(raw: primaryKeyName) != 0 }"
        let markPersistedDecl: DeclSyntax = hasTrackedPersistenceState
            ? "public func markPersisted() { self._persisted = true }"
            : "public func markPersisted() {}"
        let markNewDecl: DeclSyntax = hasTrackedPersistenceState
            ? "public func markNewRecord() { self._persisted = false }"
            : "public func markNewRecord() {}"
        let dbGeneratedDecl: DeclSyntax =
            "public static let databaseGeneratedPrimaryKey = \(raw: hasDatabaseGeneratedId ? "true" : "false")"
        // Assign the database-generated key (SQLite/D1 rowid / Postgres RETURNING) after
        // INSERT. An `Int64` PK keeps the full 64-bit value; an `Int` PK wraps (it's 32-bit
        // on the Wasm guest). Non-generated PKs keep the protocol's no-op.
        let setGeneratedIDDecl: DeclSyntax = hasDatabaseGeneratedId
            ? (databaseGeneratedKind == .int64
                ? "public func setDatabaseGeneratedID(_ generatedID: Int64) { self.\(raw: primaryKeyName) = generatedID }"
                : "public func setDatabaseGeneratedID(_ generatedID: Int64) { self.\(raw: primaryKeyName) = Int(truncatingIfNeeded: generatedID) }")
            : "public func setDatabaseGeneratedID(_ generatedID: Int64) {}"

        // 6. refresh relations (inject owner id + FK into has-many handles)
        var refreshLines: [String] = []
        for r in hasManys {
            refreshLines.append("        self.$\(r.name).ownerKey = self.primaryKeyValue")
            refreshLines.append("        self.$\(r.name).foreignKey = \"\(r.foreignKey)\"")
        }
        let refresh: DeclSyntax = """
        public func refreshRelations() {
        \(raw: refreshLines.isEmpty ? "" : refreshLines.joined(separator: "\n"))
        }
        """

        // 6b. auto-managed timestamps. Opt-in: the model declares `createdAt`/`updatedAt`
        // as either `Int64`/`Int64?` (epoch millis — PlumeKit-native) OR `String`/`String?`
        // (ISO-8601 TEXT — the database-adoption case). The storage form drives the value
        // written: epoch → `ORMClock.now()`, ISO → `ormNowISO()`. The Swift property name
        // is the trigger (the SQL column may be renamed via @Column).
        func tsMode(_ propName: String) throws -> String {
            for f in fields {
                guard case .scalar(let kind, _) = f.role, f.name == propName else { continue }
                switch kind {
                case .int64: return "ORMClock.now()"
                case .string: return "ormNowISO()"
                default:
                    throw MacroError("@Model: '\(propName)' must be Int64 (epoch millis) or String (ISO-8601) to be auto-managed")
                }
            }
            return ""
        }
        let createdExpr = try tsMode("createdAt")
        let updatedExpr = try tsMode("updatedAt")
        var touchLines: [String] = []
        if !createdExpr.isEmpty { touchLines.append("        if creating { self.createdAt = \(createdExpr) }") }
        if !updatedExpr.isEmpty { touchLines.append("        self.updatedAt = \(updatedExpr)") }
        let touch: DeclSyntax = """
        public func touchTimestamps(creating: Bool) {
        \(raw: touchLines.joined(separator: "\n"))
        }
        """
        // The SQL column name of `createdAt` (honoring @Column renames), so `upsert` can
        // preserve creation time by the RIGHT column — a hardcoded "created_at" would miss
        // a renamed column and clobber it on conflict.
        let createdAtSqlName = columns.first(where: { $0.constName == "createdAt" })?.sqlName
        let createdAtColumnDecl: DeclSyntax = createdAtSqlName.map {
            "public static let createdAtColumn: String? = \"\(raw: $0)\""
        } ?? "public static let createdAtColumn: String? = nil"

        // 6c. primary-key value as a bound parameter (overrides the protocol default, so a
        // custom/non-integer PK persists/deletes correctly). `encode` already reads `self.<pk>`.
        let pkEncode = columns.first(where: { $0.isPK })?.encode ?? "sqlInt(id)"
        let primaryKeyValueDecl: DeclSyntax = "public var primaryKeyValue: SQLValue { \(raw: pkEncode) }"
        // The PK column's type, so a child's @BelongsTo FK column can mirror it.
        let primaryKeyColumnTypeDecl: DeclSyntax = "public static let primaryKeyColumnType: ColumnType = .\(raw: primaryKeyColumnType)"

        // 7. typed query columns (keyed by the SWIFT property name for ergonomic
        // predicates: `Order.quantity == 5`; the stored string is the SQL column).
        var columnConsts: [DeclSyntax] = []
        for c in columns {
            columnConsts.append("public static let \(raw: c.constName) = Column<\(raw: typeName), \(raw: c.constType)>(\"\(raw: c.sqlName)\")")
        }

        return [
            schema, initRow, columnValues, memberwiseInit,
            snapshot, takeSnapshot, changed,
            persistedStorage, isPersistedDecl, markPersistedDecl, markNewDecl, dbGeneratedDecl, setGeneratedIDDecl,
            refresh, touch, createdAtColumnDecl, primaryKeyValueDecl, primaryKeyColumnTypeDecl,
        ] + columnConsts
    }
}

// MARK: - Field extraction

enum FieldRole {
    case scalar(FieldKind, optional: Bool)
    case belongsTo(related: String, foreignKey: String?, nullable: Bool)
    case hasMany(child: String, foreignKey: String?)
}

struct ModelField {
    let name: String
    let role: FieldRole
    let defaultExpr: String?
    let columnName: String?
}

/// True only for a genuinely COMPUTED property (`var x: T { … }` or a get/set block).
/// A property with only `willSet`/`didSet` observers is a STORED property and must keep
/// its column — treating it as computed would silently drop it from the schema.
func isComputedProperty(_ binding: PatternBindingSyntax) -> Bool {
    guard let accessorBlock = binding.accessorBlock else { return false }
    switch accessorBlock.accessors {
    case .getter:
        return true   // `var x: T { … }`
    case .accessors(let list):
        for accessor in list {
            switch accessor.accessorSpecifier.tokenKind {
            case .keyword(.get), .keyword(.set), .keyword(._read), .keyword(._modify),
                 .keyword(.unsafeAddress), .keyword(.unsafeMutableAddress):
                return true   // has a computed accessor
            default:
                continue      // willSet / didSet — an observer on a stored property
            }
        }
        return false          // only observers → stored
    }
}

func storedFields(of cls: ClassDeclSyntax) throws -> [ModelField] {
    var fields: [ModelField] = []
    for member in cls.memberBlock.members {
        guard let v = member.decl.as(VariableDeclSyntax.self) else { continue }
        if v.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) { continue }
        let attrs = parseAttributes(v.attributes)
        for binding in v.bindings {
            guard let idPat = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            if isComputedProperty(binding) { continue }  // computed (get/set) — skip; observers are stored
            let name = idPat.identifier.text
            let typeText = binding.typeAnnotation?.type.trimmedDescription
            let defaultExpr = binding.initializer?.value.trimmedDescription

            switch attrs.relationship {
            case .belongsTo:
                guard let t = typeText else { throw MacroError("@BelongsTo '\(name)' needs a type, e.g. `User?`") }
                fields.append(ModelField(name: name,
                    role: .belongsTo(related: strippedOptional(t), foreignKey: attrs.foreignKey, nullable: attrs.nullable),
                    defaultExpr: nil, columnName: attrs.columnName))
            case .hasMany:
                guard let t = typeText else { throw MacroError("@HasMany '\(name)' needs a type, e.g. `[Comment]`") }
                fields.append(ModelField(name: name, role: .hasMany(child: arrayElement(t), foreignKey: attrs.foreignKey),
                    defaultExpr: nil, columnName: nil))
            case .none:
                var optional = false
                let kind: FieldKind
                if let t0 = typeText {
                    var t = t0.trimmingCharacters(in: .whitespaces)
                    if t.hasSuffix("?") { optional = true; t = String(t.dropLast()).trimmingCharacters(in: .whitespaces) }
                    guard let k = FieldKind(swiftType: t) else {
                        throw MacroError("@Model: unsupported column type '\(t0)' for '\(name)'")
                    }
                    kind = k
                } else if let initValue = binding.initializer?.value, let k = FieldKind(literal: initValue) {
                    kind = k
                } else {
                    throw MacroError("@Model: property '\(name)' needs a type annotation")
                }
                fields.append(ModelField(name: name, role: .scalar(kind, optional: optional),
                    defaultExpr: defaultExpr, columnName: attrs.columnName))
            }
        }
    }
    return fields
}

// MARK: - Attribute parsing

enum RelationshipAttr { case belongsTo, hasMany, none }

struct ParsedAttributes {
    var relationship: RelationshipAttr = .none
    var columnName: String? = nil
    var foreignKey: String? = nil
    var nullable: Bool = false
}

func parseAttributes(_ attributes: AttributeListSyntax) -> ParsedAttributes {
    var out = ParsedAttributes()
    for attr in attributes {
        guard let a = attr.as(AttributeSyntax.self) else { continue }
        let name = a.attributeName.trimmedDescription
        let args = a.arguments?.as(LabeledExprListSyntax.self)
        switch name {
        case "BelongsTo":
            out.relationship = .belongsTo
            if let args {
                out.foreignKey = stringArgument(args, label: "foreignKey")
                if let n = boolArgument(args, label: "nullable") { out.nullable = n }
            }
        case "HasMany":
            out.relationship = .hasMany
            if let args { out.foreignKey = stringArgument(args, label: "foreignKey") }
        case "Column":
            if let args { out.columnName = firstUnlabeledStringArgument(args) }
        default:
            continue
        }
    }
    return out
}

func tableOverride(from node: AttributeSyntax) -> String? { nodeStringArgument(node, label: "table") }

/// A non-empty string-literal argument of the `@Model(...)` attribute itself.
func nodeStringArgument(_ node: AttributeSyntax, label: String) -> String? {
    guard let args = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
    guard let value = stringArgument(args, label: label), !value.isEmpty else { return nil }
    return value
}

func stringArgument(_ args: LabeledExprListSyntax, label: String) -> String? {
    for e in args where e.label?.text == label {
        return stringLiteralValue(e.expression)
    }
    return nil
}

func firstUnlabeledStringArgument(_ args: LabeledExprListSyntax) -> String? {
    for e in args where e.label == nil {
        if let s = stringLiteralValue(e.expression) { return s }
    }
    return nil
}

func boolArgument(_ args: LabeledExprListSyntax, label: String) -> Bool? {
    for e in args where e.label?.text == label {
        if let b = e.expression.as(BooleanLiteralExprSyntax.self) {
            return b.literal.tokenKind == .keyword(.true)
        }
    }
    return nil
}

func stringLiteralValue(_ expr: ExprSyntax) -> String? {
    guard let s = expr.as(StringLiteralExprSyntax.self) else { return nil }
    var out = ""
    for seg in s.segments {
        guard let str = seg.as(StringSegmentSyntax.self) else { return nil }  // reject interpolation
        out += str.content.text
    }
    return out
}

// MARK: - Swift type ↔ column kind

enum FieldKind: Equatable {
    case int, int64, uuid, string, bool, double, blob

    init?(swiftType: String) {
        switch swiftType {
        case "Int": self = .int
        case "Int64": self = .int64        // 64-bit (Int is 32-bit on wasm!)
        case "UUID", "PlumeCore.UUID", "PlumeORM.UUID": self = .uuid
        case "String": self = .string
        case "Bool": self = .bool
        case "Double": self = .double
        case "[UInt8]": self = .blob
        default: return nil
        }
    }

    init?(literal: ExprSyntax) {
        if literal.is(BooleanLiteralExprSyntax.self) { self = .bool }
        else if literal.is(IntegerLiteralExprSyntax.self) { self = .int }
        else if literal.is(StringLiteralExprSyntax.self) { self = .string }
        else if literal.is(FloatLiteralExprSyntax.self) { self = .double }
        else { return nil }
    }

    var swiftType: String {
        switch self {
        case .int: return "Int"
        case .int64: return "Int64"
        case .uuid: return "PlumeORM.UUID"
        case .string: return "String"
        case .bool: return "Bool"
        case .double: return "Double"
        case .blob: return "[UInt8]"
        }
    }

    var columnType: String {
        switch self {
        case .int, .int64: return "integer"
        case .uuid: return "uuid"
        case .string: return "text"
        case .bool: return "boolean"
        case .double: return "real"
        case .blob: return "blob"
        }
    }

    var rowAccessor: String {
        switch self {
        case .int: return "int"
        case .int64: return "int64"
        case .uuid: return "uuid"
        case .string: return "string"
        case .bool: return "bool"
        case .double: return "double"
        case .blob: return "bytes"
        }
    }

    func sqlValue(field: String) -> String {
        switch self {
        case .int, .int64: return "sqlInt(\(field))"
        case .uuid: return "sqlUUID(\(field))"
        case .string: return "sqlText(\(field))"
        case .bool: return "sqlBool(\(field))"
        case .double: return "sqlReal(\(field))"
        case .blob: return "sqlBlob(\(field))"
        }
    }

    func sqlValueOptional(field: String) -> String {
        switch self {
        case .int: return "sqlIntOptional(\(field))"
        case .int64: return "sqlInt64Optional(\(field))"
        case .uuid: return "sqlUUIDOptional(\(field))"
        case .string: return "sqlTextOptional(\(field))"
        case .bool: return "sqlBoolOptional(\(field))"
        case .double: return "sqlRealOptional(\(field))"
        case .blob: return "sqlBlobOptional(\(field))"
        }
    }

    var isIntegerID: Bool {
        switch self {
        case .int, .int64: return true   // both auto-increment; Int64 keeps full 64-bit rowids
        default: return false
        }
    }
}

// MARK: - Helpers

/// ASCII snake_case converter for Swift identifiers. Host-side only.
func snakeCaseIdentifier(_ name: String) -> String {
    let bytes = Array(name.utf8)
    if bytes.isEmpty { return name }
    var out: [UInt8] = []
    for i in 0..<bytes.count {
        let byte = bytes[i]
        if isASCIIUpper(byte) {
            let previous = i > 0 ? bytes[i - 1] : 0
            let next = i + 1 < bytes.count ? bytes[i + 1] : 0
            let needsSeparator = !out.isEmpty
                && out.last != 0x5f
                && (isASCIILower(previous) || isASCIIDigit(previous) || isASCIILower(next))
            if needsSeparator { out.append(0x5f) }
            out.append(byte + 32)
        } else if byte == 0x2d || byte == 0x20 {
            if !out.isEmpty && out.last != 0x5f { out.append(0x5f) }
        } else {
            out.append(byte)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

private func isASCIIUpper(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5a }
private func isASCIILower(_ byte: UInt8) -> Bool { byte >= 0x61 && byte <= 0x7a }
private func isASCIIDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

/// Naive English pluraliser for table names. Host-side only.
func pluralize(_ word: String) -> String {
    if word.hasSuffix("y"), let last = word.dropLast().last, !"aeiou".contains(last) {
        return word.dropLast() + "ies"
    }
    if word.hasSuffix("s") || word.hasSuffix("x") || word.hasSuffix("z")
        || word.hasSuffix("ch") || word.hasSuffix("sh") {
        return word + "es"
    }
    return word + "s"
}

struct MacroError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func strippedOptional(_ type: String) -> String {
    var t = type.trimmingCharacters(in: .whitespaces)
    if t.hasSuffix("?") { t = String(t.dropLast()) }
    return t.trimmingCharacters(in: .whitespaces)
}

func arrayElement(_ type: String) -> String {
    var t = type.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("[") && t.hasSuffix("]") { t = String(t.dropFirst().dropLast()) }
    return t.trimmingCharacters(in: .whitespaces)
}
