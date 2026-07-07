import Testing
@testable import PlumeCore
import PlumeORM
import PlumeServer

@Model
final class Account: Model {
    var id: Int
    var username: String
    var age = 0

    static let validations: [Validation<Account>] = [
        .presence("username") { $0.username },
        .length("username", min: 2, max: 10) { $0.username },
        .atLeast("age", 0) { $0.age },
    ]
    static let asyncValidations: [AsyncValidation<Account>] = [
        .unique("username", column: "username") { sqlText($0.username) },
    ]
}

@Test func syncValidationsBlockInvalidSave() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Account.createTable(in: db)

    let ok = Account(username: "alice", age: 30)
    #expect(ok.validate().isEmpty)
    try await ok.save(in: db)
    #expect(ok.id > 0)

    let bad = Account(username: "", age: -1)
    let errors = bad.validate()
    #expect(errors.contains { $0.field == "username" })   // presence + length
    #expect(errors.contains { $0.field == "age" })        // atLeast

    // save returns the errors and does NOT persist (validation is a value, not a throw)
    let saveErrors = try await bad.save(in: db)
    #expect(!saveErrors.isEmpty)
    #expect(bad.id == 0)   // not persisted
}

@Test func uniquenessExcludesSelf() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Account.createTable(in: db)
    try await Account(username: "bob", age: 20).save(in: db)

    // A different row with the same username fails (errors returned, not persisted).
    let dupeErrors = try await Account(username: "bob", age: 25).save(in: db)
    #expect(dupeErrors.contains { $0.field == "username" })

    // Updating the SAME row keeps its username valid (excludes self).
    let bob = try await Account.where(Account.username == "bob").all(in: db).first!
    bob.age = 21
    try await bob.save(in: db)
    #expect(try await Account.all().count(in: db) == 1)
}
