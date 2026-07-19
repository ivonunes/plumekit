import Testing
@testable import PlumeCore
@testable import PlumeORM
@testable import PlumeServer

@Model
final class Widget2: Model {
    var id: Int
    var name: String
}

@Model(table: "adopted_rows")
final class AdoptedRow: Model {
    var id: Int
    var label: String
    @Column("created") var createdAt: Int64? = nil   // renamed timestamp column
}

@Test func paginateDoesNotOverflowOnHugePageAndPer() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Widget2.createTable(in: db)
    for i in 0..<3 { let w = Widget2(name: "n\(i)"); _ = try await w.save(in: db) }
    // (page-1)*per would trap without the saturating multiply; expect an empty page, no crash.
    let page = try await Widget2.query().paginate(page: 2_000_000, per: 2_000_000, in: db)
    #expect(page.items.isEmpty && page.hasMore == false)
    let ok = try await Widget2.query().order(by: Widget2.id).paginate(page: 1, per: 2, in: db)
    #expect(ok.items.count == 2 && ok.hasMore)
}

@Test func upsertPreservesRenamedCreatedAtColumn() async throws {
    #expect(AdoptedRow.createdAtColumn == "created")     // real column, not "created_at"
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await AdoptedRow.createTable(in: db)
    let a = AdoptedRow(label: "first"); a.id = 1
    _ = try await a.upsert(in: db)
    let created1 = try #require(await AdoptedRow.find(1, in: db)).createdAt
    #expect(created1 != nil)
    let b = AdoptedRow(label: "second"); b.id = 1        // conflict on the same PK
    _ = try await b.upsert(in: db)
    let created2 = try #require(await AdoptedRow.find(1, in: db)).createdAt
    #expect(created2 == created1)                        // creation time preserved (not clobbered)
}
