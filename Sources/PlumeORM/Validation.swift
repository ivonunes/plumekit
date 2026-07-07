import PlumeCore
import _Concurrency

// Validations: declared as concrete value types holding closures (NO keypaths —
// they're forbidden under embedded wasm), so they run identically on D1 and native
// SQLite. Field rules are synchronous; uniqueness is async (a query through the neutral
// SQLDatabase). `save()` validates first and throws ValidationFailed on errors.
//
// Text length counts UTF-8 BYTES, not graphemes — `String.count` needs Unicode
// tables that don't link under embedded wasm. No regex for
// the same reason; use `custom` with byte-level checks.

public struct ValidationError: Sendable {
    public let field: String
    public let message: String
    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }
}

/// A synchronous field rule. `field`/`Value` are read via a closure (no keypath).
public struct Validation<M>: @unchecked Sendable {
    let field: String
    let check: @Sendable (M) -> String?   // nil = valid; otherwise the message

    public static func presence(_ field: String, _ value: @escaping @Sendable (M) -> String) -> Validation {
        Validation(field: field, check: { value($0).utf8.isEmpty ? "can't be blank" : nil })
    }

    public static func length(
        _ field: String, min: Int = 0, max: Int = Int.max, _ value: @escaping @Sendable (M) -> String
    ) -> Validation {
        Validation(field: field, check: { model in
            let count = value(model).utf8.count   // bytes, not graphemes
            if count < min { return "is too short (minimum is \(min))" }
            if count > max { return "is too long (maximum is \(max))" }
            return nil
        })
    }

    public static func atLeast(_ field: String, _ minimum: Int, _ value: @escaping @Sendable (M) -> Int) -> Validation {
        Validation(field: field, check: { value($0) < minimum ? "must be at least \(minimum)" : nil })
    }

    public static func atMost(_ field: String, _ maximum: Int, _ value: @escaping @Sendable (M) -> Int) -> Validation {
        Validation(field: field, check: { value($0) > maximum ? "must be at most \(maximum)" : nil })
    }

    public static func custom(_ field: String, _ check: @escaping @Sendable (M) -> String?) -> Validation {
        Validation(field: field, check: check)
    }
}

/// An asynchronous rule (e.g. uniqueness) that may query the database.
public struct AsyncValidation<M>: @unchecked Sendable {
    let field: String
    let check: (M, Database) async throws -> String?

    public static func custom(
        _ field: String, _ check: @escaping (M, Database) async throws -> String?
    ) -> AsyncValidation {
        AsyncValidation(field: field, check: check)
    }
}

extension AsyncValidation where M: Model {
    /// No other row may share `value` in `column` (excluding this instance).
    public static func unique(
        _ field: String, column: String, _ value: @escaping @Sendable (M) -> SQLValue
    ) -> AsyncValidation {
        let table = M.schema.table
        let primaryKeyColumn = M.primaryKeyColumn
        return AsyncValidation(field: field, check: { model, db in
            let result = try await db.query(
                "SELECT " + primaryKeyColumn + " FROM " + table
                    + " WHERE " + column + " = ? AND " + primaryKeyColumn + " <> ? LIMIT 1",
                [value(model), model.primaryKeyValue])
            return result.rows.isEmpty ? nil : "has already been taken"
        })
    }
}
