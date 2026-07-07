import PlumeCore

// Model ⇄ JSON, reusing the @Model row codec (designed from the start to also
// back JSON). Encoding walks schema.columns + columnValues();
// decoding maps a JSON object back into a Row by column name. Reflection-free.

extension Model {
    /// A JSON object of this model's columns (`{ "id": 1, "title": "…" }`).
    public func jsonObject() -> JSONValue {
        var pairs: [(name: String, value: JSONValue)] = []
        let values = columnValues()
        for (i, column) in Self.schema.columns.enumerated() {
            pairs.append((name: column.name, value: jsonFromSQL(values[i], column.type)))
        }
        return .object(pairs)
    }

    /// Build a fresh instance from a JSON object (by column name → positional Row).
    /// Absent keys (e.g. `id` on create) get type defaults — so the result inserts.
    public static func fromJSON(_ json: JSONValue) -> Self {
        var values: [SQLValue] = []
        for column in schema.columns {
            let value = json[column.name]
            if column.isNullable, isJSONNull(value) {
                values.append(.null)
            } else {
                values.append(sqlFromJSON(value, column.type))
            }
        }
        let model = Self(row: Row(values))
        model.markNewRecord()
        return model
    }
}

/// A JSON array of model objects.
public func jsonArray<M: Model>(_ models: [M]) -> JSONValue {
    .array(models.map { $0.jsonObject() })
}

func jsonFromSQL(_ value: SQLValue, _ type: ColumnType) -> JSONValue {
    switch value {
    case .null: return .null
    case .integer(let n):
        if case .boolean = type { return .bool(n != 0) }
        return .int(n)
    case .double(let d): return .double(d)
    case .text(let s): return .string(s)
    case .blob: return .null   // blobs aren't JSON-encoded inline
    }
}

func sqlFromJSON(_ json: JSONValue?, _ type: ColumnType) -> SQLValue {
    guard let json else {
        switch type {
        case .integer, .boolean: return .integer(0)
        case .uuid: return .text(UUID().uuidString)
        case .real: return .double(0)
        case .text: return .text("")
        case .blob: return .blob([])
        }
    }
    switch type {
    case .integer: return .integer(json.intValue ?? 0)
    case .uuid: return .text(json.stringValue ?? UUID().uuidString)
    case .boolean:
        let truthy = json.boolValue ?? ((json.intValue ?? 0) != 0)
        return .integer(truthy ? 1 : 0)
    case .real: return .double(json.doubleValue ?? 0)
    case .text: return .text(json.stringValue ?? "")
    case .blob: return .blob([])
    }
}

private func isJSONNull(_ json: JSONValue?) -> Bool {
    guard let json else { return true }
    if case .null = json { return true }
    return false
}
