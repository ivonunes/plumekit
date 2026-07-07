import Testing
@testable import PlumeCore
@testable import PlumeORM
@testable import PlumeServer

@Model
final class BigEvent: Model {
    var id: Int64          // 64-bit auto-increment PK (large D1 rowids stay faithful)
    var name: String
}

@Test func int64PrimaryKeyAutoIncrements() async throws {
    #expect(BigEvent.databaseGeneratedPrimaryKey)          // now database-generated (was false before)
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await BigEvent.createTable(in: db)
    let a = BigEvent(name: "a")                            // id NOT required in init
    try await a.save(in: db)
    #expect(a.id != 0)                                     // rowid assigned post-insert
    let b = BigEvent(name: "b")
    try await b.save(in: db)
    #expect(b.id == a.id + 1)                              // auto-increments
    let loaded = try #require(await BigEvent.find(a.id, in: db))
    #expect(loaded.name == "a")
}

@Test func int64PrimaryKeyKeepsFullWidthPastInt32() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await BigEvent.createTable(in: db)
    // Seed a rowid past 2^31 and insert after it; the returned id must not truncate.
    _ = try await db.query("INSERT INTO big_events (id, name) VALUES (?, ?)", [.integer(3_000_000_000), .text("seed")])
    let e = BigEvent(name: "next")
    try await e.save(in: db)
    #expect(e.id == 3_000_000_001)                         // full 64-bit, no 32-bit truncation
}

@Test func findByRequestReturnsInt64PkRowPastInt32() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await BigEvent.createTable(in: db)
    _ = try await db.query("INSERT INTO big_events (id, name) VALUES (?, ?)", [.integer(3_000_000_001), .text("big")])
    var req = Request(method: .get, path: "/")
    req.parameters.set("id", "3000000001")
    // Route model binding must parse the id as Int64 — on the guest, Int(raw) would
    // overflow to nil and 404 this real row (the whole point of the Int64 PK).
    let found = try await BigEvent.find(req, in: db)
    #expect(found != nil && found!.name == "big")
}

@Model(primaryKey: "code")
final class Widget: Model {
    var code: Int
    var label: String
}

@Test func nonIdIntegerPrimaryKeyAutoIncrements() async throws {
    #expect(Widget.databaseGeneratedPrimaryKey)            // was false before (name != "id")
    #expect(Widget.primaryKeyColumn == "code")
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Widget.createTable(in: db)
    let w = Widget(label: "x")                             // `code` NOT required in init
    try await w.save(in: db)
    #expect(w.code != 0)                                   // database-assigned
    let w2 = Widget(label: "y")
    try await w2.save(in: db)
    #expect(w2.code == w.code + 1)                         // auto-increments
    let found = try #require(await Widget.find(w.code, in: db))
    #expect(found.label == "x")
}
