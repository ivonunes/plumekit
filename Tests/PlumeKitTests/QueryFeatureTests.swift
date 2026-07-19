import Testing
@testable import PlumeCore
import PlumeORM
import PlumeServer

// The query builder's bulk writes, aggregates, composed ordering and
// request-driven pagination.

@Model
final class Metric: Model {
    var id: Int
    var label: String
    var views = 0
    var score = 0.0
}

private func seed(_ db: Database) async throws {
    try await Metric.createTable(in: db)
    for (label, views, score) in [("a", 10, 1.5), ("b", 20, 2.5), ("c", 30, 4.0)] {
        let metric = Metric(label: label, views: views, score: score)
        _ = try await metric.save(in: db)
    }
}

@Test func updateAllAndDeleteWriteInOneStatement() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await seed(db)

    let updated = try await Metric.where(Metric.views >= 20)
        .updateAll(Metric.views.set(0), Metric.label.set("reset"), in: db)
    #expect(updated == 2)
    #expect(try await Metric.where(Metric.views == 0).count(in: db) == 2)
    #expect(try await Metric.where(Metric.label == "reset").count(in: db) == 2)

    let deleted = try await Metric.where(Metric.views == 0).delete(in: db)
    #expect(deleted == 2)
    #expect(try await Metric.count(in: db) == 1)

    // No matching rows → zero affected, no error.
    #expect(try await Metric.where(Metric.views == 999).delete(in: db) == 0)
}

@Test func aggregatesComputeInSQL() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await seed(db)

    #expect(try await Metric.query().sum(Metric.views, in: db) == 60)
    #expect(try await Metric.query().sum(Metric.score, in: db) == 8.0)
    #expect(try await Metric.query().average(Metric.views, in: db) == 20)
    #expect(try await Metric.query().minimum(Metric.views, in: db) == 10)
    #expect(try await Metric.query().maximum(Metric.views, in: db) == 30)
    #expect(try await Metric.query().maximum(Metric.score, in: db) == 4.0)

    // Aggregates respect the predicate.
    #expect(try await Metric.where(Metric.views > 10).sum(Metric.views, in: db) == 50)

    // Empty set: sums are 0, the others nil.
    _ = try await Metric.query().delete(in: db)
    #expect(try await Metric.query().sum(Metric.views, in: db) == 0)
    #expect(try await Metric.query().average(Metric.views, in: db) == nil)
    #expect(try await Metric.query().minimum(Metric.views, in: db) == nil)
}

@Test func orderCallsCompose() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Metric.createTable(in: db)
    for (label, views) in [("x", 1), ("y", 2), ("z", 2)] {
        _ = try await Metric(label: label, views: views).save(in: db)
    }

    // views DESC first, then label DESC within the tie — the second order
    // composes instead of replacing the first.
    let rows = try await Metric.query()
        .order(by: Metric.views, .descending)
        .order(by: Metric.label, .descending)
        .all(in: db)
    #expect(rows.map { $0.label } == ["z", "y", "x"])
}

@Test func paginateReadsPageAndPerFromTheRequest() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Metric.createTable(in: db)
    for i in 1...5 { _ = try await Metric(label: "m\(i)", views: i).save(in: db) }

    let request = Request(method: .get, path: "/metrics", query: "page=2&per=2")
    let page = try await Metric.query().order(by: Metric.id).paginate(request, in: db)
    #expect(page.items.map { $0.views } == [3, 4])
    #expect(page.page == 2)
    #expect(page.hasMore)
    // The links it renders carry the same names it just read.
    #expect(page.nextURL("/metrics") == "/metrics?page=3&per=2")

    // `per` is clamped: user input can't request an unbounded page.
    let greedy = Request(method: .get, path: "/metrics", query: "per=99999")
    let clamped = try await Metric.query().order(by: Metric.id).paginate(greedy, maxPer: 3, in: db)
    #expect(clamped.items.count == 3)

    // No params → defaults (page 1).
    let bare = Request(method: .get, path: "/metrics")
    let first = try await Metric.query().order(by: Metric.id).paginate(bare, per: 2, in: db)
    #expect(first.items.map { $0.views } == [1, 2])
}
