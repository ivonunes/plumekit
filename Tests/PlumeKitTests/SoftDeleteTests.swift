import Testing
import PlumeCore
import PlumeServer
import PlumeORM

@Suite struct SoftDeleteTests {
    @Model final class Note: Model, SoftDeletable {
        var id: Int
        var text: String
        var deletedAt = 0
    }

    private func makeDatabase() async throws -> Database {
        NativeDrivers.installNativeClock()
        let db = try NativeDrivers.sqlite(path: ":memory:")
        try await Note.createTable(in: db)
        return db
    }

    @Test func softDeleteHidesRestoreRevives() async throws {
        let db = try await makeDatabase()
        let keep = Note(text: "keep"); _ = try await keep.save(in: db)
        let trash = Note(text: "trash"); _ = try await trash.save(in: db)

        try await trash.softDelete(in: db)

        // Hidden from queries, counts, and find — but withTrashed sees everything.
        #expect(try await Note.all().all(in: db).count == 1)
        #expect(try await Note.all().count(in: db) == 1)
        #expect(try await Note.find(trash.id, in: db) == nil)
        #expect(try await Note.withTrashed().all(in: db).count == 2)
        #expect(try await Note.onlyTrashed().all(in: db).first?.text == "trash")

        try await trash.restore(in: db)
        #expect(try await Note.all().all(in: db).count == 2)
        #expect(try await Note.find(trash.id, in: db)?.text == "trash")
    }

    @Test func scopeComposesWithWhere() async throws {
        let db = try await makeDatabase()
        let a = Note(text: "match"); _ = try await a.save(in: db)
        let b = Note(text: "match"); _ = try await b.save(in: db)
        try await b.softDelete(in: db)

        // where() ANDs with the default scope; unscoped drops it.
        #expect(try await Note.where(Note.text == "match").all(in: db).count == 1)
        #expect(try await Note.where(Note.text == "match").unscoped().all(in: db).count == 2)
    }

    @Test func forceDeleteActuallyRemovesTheRow() async throws {
        let db = try await makeDatabase()
        let note = Note(text: "gone"); _ = try await note.save(in: db)
        try await note.forceDelete(in: db)
        #expect(try await Note.withTrashed().all(in: db).isEmpty)
    }
}

@Suite(.serialized) struct ModelCallbackTests {
    @Model final class Article: Model {
        var id: Int
        var title: String
        var slug = ""

        // Derive the slug on save; refuse to delete a protected row; record order.
        func willSave() async throws {
            slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
            CallbackLog.shared.append("willSave")
        }
        func didSave() async throws { CallbackLog.shared.append("didSave") }
        func willDelete() async throws {
            if title == "protected" { throw Protected() }
            CallbackLog.shared.append("willDelete")
        }
        func didDelete() async throws { CallbackLog.shared.append("didDelete") }
    }

    struct Protected: Error {}

    final class CallbackLog: @unchecked Sendable {
        static let shared = CallbackLog()
        private(set) var events: [String] = []
        func append(_ event: String) { events.append(event) }
        func reset() { events = [] }
    }

    @Test func hooksFireInOrderAndCanTransformFields() async throws {
        CallbackLog.shared.reset()
        let db = try NativeDrivers.sqlite(path: ":memory:")
        try await Article.createTable(in: db)
        CallbackLog.shared.reset()

        let article = Article(title: "Hello World")
        _ = try await article.save(in: db)
        #expect(article.slug == "hello-world")               // willSave mutation persisted
        #expect(try await Article.find(article.id, in: db)?.slug == "hello-world")

        try await article.delete(in: db)
        #expect(CallbackLog.shared.events == ["willSave", "didSave", "willDelete", "didDelete"])
    }

    @Test func throwingWillDeleteAbortsTheDelete() async throws {
        CallbackLog.shared.reset()
        let db = try NativeDrivers.sqlite(path: ":memory:")
        try await Article.createTable(in: db)
        let article = Article(title: "protected")
        _ = try await article.save(in: db)

        await #expect(throws: Protected.self) { try await article.delete(in: db) }
        #expect(try await Article.find(article.id, in: db) != nil)   // still there
    }
}
