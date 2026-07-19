import Testing
@testable import PlumeORM
@testable import PlumeServer

@Model
final class ObservedModel: Model {
    var id: Int
    var views: Int = 0 { didSet { _ = oldValue } }   // observer — must NOT drop the column
    var name: String
}

@Test func observedStoredPropertyStillBecomesAColumn() async throws {
    #expect(ObservedModel.schema.columns.contains { $0.name == "views" })   // was silently dropped before the fix
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await ObservedModel.createTable(in: db)
    let m = ObservedModel(views: 7, name: "x")
    _ = try await m.save(in: db)
    let loaded = try #require(await ObservedModel.find(m.id, in: db))
    #expect(loaded.views == 7 && loaded.name == "x")   // column persists + round-trips
}
