import Testing
import PlumeCore
import PlumeServer
import PlumeORM

@Suite struct SchemaBuilderTests {
    private func db() throws -> Database { try NativeDrivers.sqlite(path: ":memory:") }

    @Test func createsAndAltersTablesExplicitly() async throws {
        let db = try db()
        // Explicit, frozen schema — spelled out, not derived from any model.
        try await db.createTable("posts") { t in
            t.id()
            t.text("title")
            t.text("body", nullable: true)
            t.references("author", table: "users")
            t.timestamps()
        }
        // Insert respecting NOT NULL (title) and the FK column (author_id).
        _ = try await db.query("INSERT INTO posts (title, author_id) VALUES (?, ?)",
                               [.text("Hello"), .integer(1)])
        // NOT NULL is enforced: a missing title must fail.
        await #expect(throws: (any Error).self) {
            _ = try await db.query("INSERT INTO posts (author_id) VALUES (?)", [.integer(1)])
        }

        // Alter: add, rename, drop.
        try await db.alterTable("posts") { t in
            t.addColumn("slug", .text, nullable: true)
            t.renameColumn("body", to: "content")
        }
        _ = try await db.query("INSERT INTO posts (title, author_id, slug, content) VALUES (?, ?, ?, ?)",
                               [.text("Two"), .integer(1), .text("two"), .text("...")])

        try await db.alterTable("posts") { t in t.dropColumn("slug") }
        // slug is gone: selecting it errors.
        await #expect(throws: (any Error).self) {
            _ = try await db.query("SELECT slug FROM posts", [])
        }

        // Index + drop.
        try await db.addIndex(on: "posts", columns: ["author_id"])
        try await db.dropIndex("idx_posts_author_id")

        // Rename + drop table.
        try await db.renameTable("posts", to: "articles")
        #expect(try await db.query("SELECT COUNT(*) FROM articles", []).rows.count == 1)
        try await db.dropTable("articles")
        await #expect(throws: (any Error).self) {
            _ = try await db.query("SELECT 1 FROM articles", [])
        }
    }
}
