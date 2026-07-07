import Testing
@testable import PlumeCore
import PlumeORM
import PlumeServer

// Step 4: relationships — @BelongsTo / @HasMany, explicit async load, batched
// eager loading with no N+1.

@Model
final class Author: Model {
    var id: Int
    var name: String
    @HasMany var articles: [Article]
}

@Model
final class Article: Model {
    var id: Int
    var title: String
    @BelongsTo var author: Author?
}

private func eq(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }

/// Wraps a Database and counts queries — to prove eager loading isn't N+1.
final class CountingDB: SQLDatabase, @unchecked Sendable {
    let inner: Database
    var count = 0
    init(_ inner: Database) { self.inner = inner }
    func query(_ sql: String, _ parameters: [SQLValue]) async throws -> QueryResult {
        count += 1
        return try await inner.query(sql, parameters)
    }
}

@Test func belongsToGeneratesFKColumn() {
    // @BelongsTo var author → an `author_id` integer column.
    let cols = Article.schema.columns
    #expect(cols.contains { eq($0.name, "author_id") })
    #expect(cols.contains { eq($0.name, "id") && $0.isPrimaryKey })
    // @HasMany is NOT a column on the owner.
    #expect(!Author.schema.columns.contains { eq($0.name, "articles") })
}

@Test func belongsToAndHasManyExplicitLoad() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Author.createTable(in: db)
    try await Article.createTable(in: db)

    let author = Author(name: "Ada")
    try await author.save(in: db)
    #expect(author.id > 0)

    try await Article(title: "one", author: author).save(in: db)
    try await Article(title: "two", author: author).save(in: db)

    // BelongsTo: load the parent from a freshly-found child (only the FK is set).
    let articles = try await Article.all().all(in: db)
    let parent = try await articles[0].$author.load(in: db)
    #expect(parent != nil)
    #expect(eq(parent!.name, "Ada"))

    // HasMany: explicit load keyed on the FK (owner id injected on save).
    let mine = try await author.$articles.load(in: db)
    #expect(mine.count == 2)
}

@Test func eagerLoadAvoidsNPlusOne() async throws {
    let counting = CountingDB(try NativeDrivers.sqlite(path: ":memory:"))
    let db = Database(counting)
    try await Author.createTable(in: db)
    try await Article.createTable(in: db)

    let a = Author(name: "A"); try await a.save(in: db)
    let b = Author(name: "B"); try await b.save(in: db)
    try await Article(title: "1", author: a).save(in: db)
    try await Article(title: "2", author: a).save(in: db)
    try await Article(title: "3", author: b).save(in: db)

    let authors = try await Author.all().all(in: db)
    #expect(authors.count == 2)

    let before = counting.count
    try await eagerLoad(authors, foreignKey: "author_id",
        childKey: { (c: Article) in c.$author.key },
        assign: { (owner: Author, kids: [Article]) in owner.$articles.cached = kids },
        in: db)
    let queriesIssued = counting.count - before
    #expect(queriesIssued == 1)   // ONE child query for ALL authors — not N+1

    var total = 0
    for author in authors { total += author.$articles.cached?.count ?? -100 }
    #expect(total == 3)           // grouped correctly: A→2, B→1
}

// A UUID-primary-key parent with relations (previously a compile error / silent
// mis-grouping) — the FK now carries the raw key of any type.
@Model
final class Workspace: Model {
    var id: PlumeORM.UUID = PlumeORM.UUID()
    var name: String
    @HasMany var projects: [Project]
}

@Model
final class Project: Model {
    var id: Int
    var title: String
    @BelongsTo var workspace: Workspace?
}

@Test func belongsToFKMirrorsParentKeyType() {
    // Project.workspace_id mirrors Workspace's UUID primary key, not a bare integer.
    #expect(Workspace.primaryKeyColumnType == .uuid)
    let fk = Project.schema.columns.first { eq($0.name, "workspace_id") }
    #expect(fk?.type == .uuid)
}

@Test func relationsWorkWithUUIDPrimaryKey() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Workspace.createTable(in: db)
    try await Project.createTable(in: db)

    let ws = Workspace(name: "Acme")
    try await ws.save(in: db)

    try await Project(title: "alpha", workspace: ws).save(in: db)
    try await Project(title: "beta", workspace: ws).save(in: db)

    // BelongsTo across a UUID key: load the parent from a freshly-found child.
    let projects = try await Project.all().all(in: db)
    let parent = try await projects[0].$workspace.load(in: db)
    #expect(parent != nil)
    #expect(eq(parent!.name, "Acme"))

    // HasMany keyed on the UUID owner key (would have grouped under 0 before).
    let mine = try await ws.$projects.load(in: db)
    #expect(mine.count == 2)
}

// @HasMany(foreignKey:) — the reverse of a database-first @BelongsTo(foreignKey:).
@Model final class Team: Model {
    var id: Int
    var name: String
    @HasMany(foreignKey: "squad_id") var members: [Member]
}
@Model final class Member: Model {
    var id: Int
    var handle: String
    @BelongsTo(foreignKey: "squad_id") var team: Team?
}

@Test func hasManyHonorsCustomForeignKey() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Team.createTable(in: db)
    try await Member.createTable(in: db)
    let team = Team(name: "Alpha")
    try await team.save(in: db)
    try await Member(handle: "a", team: team).save(in: db)
    try await Member(handle: "b", team: team).save(in: db)
    let members = try await team.$members.load(in: db)   // WHERE squad_id = ?, not team_id
    #expect(members.count == 2)
}

@Test func belongsToResolvesKeyWhenParentSavedAfterAssignment() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Author.createTable(in: db)
    try await Article.createTable(in: db)
    let author = Author(name: "Late")
    let article = Article(title: "x", author: author)   // author.id is still 0 at assignment
    try await author.save(in: db)                        // id assigned only now
    try await article.save(in: db)                       // must persist the real FK, not 0
    let parent = try await (try await Article.all().all(in: db))[0].$author.load(in: db)
    #expect(parent != nil && eq(parent!.name, "Late"))
}

@Test func belongsToNilClearsForeignKey() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Author.createTable(in: db)
    try await Article.createTable(in: db)
    let author = Author(name: "X")
    try await author.save(in: db)
    let article = Article(title: "t", author: author)
    try await article.save(in: db)
    #expect(article.$author.id == author.id)     // FK set
    article.author = nil                          // must clear the FK, not leave it stale
    try await article.save(in: db)
    let reloaded = try #require(await Article.find(article.id, in: db))
    #expect(reloaded.$author.id == 0)             // persisted as NULL
}

@Test func findByRequestSupportsUUIDPrimaryKey() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Workspace.createTable(in: db)
    let ws = Workspace(name: "Acme")
    try await ws.save(in: db)
    let h = Headers()
    var req = Request(method: .get, path: "/", headers: h)
    req.parameters.set("id", ws.id.uuidString.uppercased())   // upper-case segment must still match
    let found = try await Workspace.find(req, in: db)
    #expect(found != nil && eq(found!.name, "Acme"))
}
