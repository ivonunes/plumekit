import Testing
import PlumeCore
import PlumeServer
import PlumeORM

@Suite struct PaginationTests {
    @Model final class PagedItem: Model {
        var id: Int
        var label: String
    }

    private func seeded(_ n: Int) async throws -> Database {
        let db = try NativeDrivers.sqlite(path: ":memory:")
        try await PagedItem.createTable(in: db)
        for i in 1...n { _ = try await PagedItem(label: "r\(i)").save(in: db) }
        return db
    }

    @Test func pageNumbersUrlsAndTotals() async throws {
        let db = try await seeded(45)
        let page = try await PagedItem.query().order(by: PagedItem.id).paginate(page: 2, per: 20, withTotal: true, in: db)

        #expect(page.items.count == 20)
        #expect(page.page == 2)
        #expect(page.previousPage == 1)
        #expect(page.nextPage == 3)
        #expect(page.total == 45)
        #expect(page.totalPages == 3)
        #expect(page.nextURL("/rows") == "/rows?page=3&per=20")
        #expect(page.previousURL("/rows") == "/rows?page=1&per=20")
    }

    @Test func edgesHaveNoDanglingLinks() async throws {
        let db = try await seeded(25)
        let first = try await PagedItem.query().order(by: PagedItem.id).paginate(page: 1, per: 20, in: db)
        #expect(first.previousPage == nil && first.previousURL("/rows") == nil)
        #expect(first.nextPage == 2)
        #expect(first.total == nil)   // no COUNT unless asked

        let last = try await PagedItem.query().order(by: PagedItem.id).paginate(page: 2, per: 20, in: db)
        #expect(last.items.count == 5)
        #expect(last.nextPage == nil && last.nextURL("/rows") == nil)
    }
}

extension PaginationTests {
    @Test func paginationURLsHandleExistingQueryString() async throws {
        let db = try await seeded(30)
        let page = try await PagedItem.query().order(by: PagedItem.id).paginate(page: 1, per: 10, in: db)
        #expect(page.nextURL("/rows") == "/rows?page=2&per=10")
        #expect(page.nextURL("/rows?tag=swift") == "/rows?tag=swift&page=2&per=10")   // & not a 2nd ?
    }

    @Test func nonPositivePageSizeIsClamped() async throws {
        let db = try await seeded(5)
        let page = try await PagedItem.query().order(by: PagedItem.id).paginate(page: 1, per: 0, in: db)
        #expect(page.items.count == 1)     // per<=0 clamped to 1, not "whole table"
    }
}
