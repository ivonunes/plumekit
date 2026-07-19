import Testing
@testable import PlumeCore
import PlumeORM
import PlumeServer

// Prove @Model lowers a trivial model to the expected
// schema + a reflection-free, positional row codec — in memory, fast.

@Model
final class Post: Model {
    var id: Int
    var title: String
    var body: String
    var published = false
}

@Model
final class UserProfile: Model {
    var id: Int
    var displayName: String
    var createdAt: String?
}

@Model
final class APIAccessToken: Model {
    var id: PlumeCore.UUID
    var label: String
}

private func bytesEqual(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }

@Test func modelMacroGeneratesSchema() {
    let s = Post.schema
    #expect(bytesEqual(s.table, "posts"))               // pluralised, lowercased
    #expect(s.columns.count == 4)
    #expect(bytesEqual(s.columns[0].name, "id"))
    #expect(s.columns[0].isPrimaryKey)
    if case .integer = s.columns[0].type {} else { Issue.record("id should be integer") }
    #expect(bytesEqual(s.columns[1].name, "title"))
    if case .text = s.columns[1].type {} else { Issue.record("title should be text") }
    if case .boolean = s.columns[3].type {} else { Issue.record("published should be boolean") }
    #expect(s.insertableColumns.count == 3)             // PK excluded
}

@Test func modelMacroDefaultsToSnakeCaseNames() {
    let s = UserProfile.schema
    #expect(bytesEqual(s.table, "user_profiles"))
    #expect(bytesEqual(s.columns[1].name, "display_name"))
    #expect(bytesEqual(s.columns[2].name, "created_at"))
    #expect(s.columns[0].isDatabaseGenerated)
}

@Test func modelMacroRowCodecRoundTrips() {
    let post = Post(title: "Hello & <World>", body: "b", published: true)
    #expect(post.id == 0)                                // unsaved

    // encode → SQLValues in schema order
    let values = post.columnValues()
    #expect(values.count == 4)
    if case .integer(let n) = values[0] { #expect(n == 0) } else { Issue.record("id value") }
    if case .text(let t) = values[1] { #expect(bytesEqual(t, "Hello & <World>")) } else { Issue.record("title value") }
    if case .integer(let b) = values[3] { #expect(b == 1) } else { Issue.record("published value") }

    // decode a positional row → instance
    let decoded = Post(row: Row([.integer(42), .text("T"), .text("B"), .integer(0)]))
    #expect(decoded.id == 42)
    #expect(bytesEqual(decoded.title, "T"))
    #expect(decoded.published == false)
}

@Test func modelMacroDirtyTracking() {
    let post = Post(row: Row([.integer(1), .text("a"), .text("b"), .integer(0)]))
    #expect(post.changedColumnIndices().isEmpty)        // freshly snapshotted = clean
    post.title = "changed"
    #expect(post.changedColumnIndices() == [1])         // only title
    post.published = true
    #expect(post.changedColumnIndices() == [1, 3])
    post.takeSnapshot()
    #expect(post.changedColumnIndices().isEmpty)
}

// Step 2: persistence round-trip through native SQLite (the same generic save/
// find/delete that runs against D1).
@Test func savePopulatesIdFindUpdateDeleteSQLite() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Post.createTable(in: db)

    let post = Post(title: "Hi", body: "world", published: false)
    #expect(post.id == 0)
    _ = try await post.save(in: db)             // INSERT
    #expect(post.id > 0)                     // id populated from lastInsertID

    let found = try await Post.find(post.id, in: db)
    #expect(found != nil)
    #expect(bytesEqual(found!.title, "Hi"))
    #expect(bytesEqual(found!.body, "world"))
    #expect(found!.published == false)

    // Dirty UPDATE — flip only `published`; `title`/`body` untouched.
    found!.published = true
    #expect(found!.changedColumnIndices() == [3])
    _ = try await found!.save(in: db)
    _ = try await found!.save(in: db)            // second save: no changes → no-op
    let reloaded = try await Post.find(post.id, in: db)
    #expect(reloaded!.published == true)
    #expect(bytesEqual(reloaded!.title, "Hi"))

    try await reloaded!.delete(in: db)
    #expect(try await Post.find(post.id, in: db) == nil)
}

@Test func insertsTwoRowsWithDistinctIds() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Post.createTable(in: db)
    let a = Post(title: "a", body: "", published: false)
    let b = Post(title: "b", body: "", published: false)
    _ = try await a.save(in: db)
    _ = try await b.save(in: db)
    #expect(a.id > 0 && b.id > 0 && a.id != b.id)
}

// Step 3: typed query builder — where / order / limit / count / all.
@Test func queryBuilderWhereOrderLimitCount() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Post.createTable(in: db)
    for (title, pub) in [("a", true), ("b", false), ("c", true), ("d", true)] {
        _ = try await Post(title: title, body: "", published: pub).save(in: db)
    }

    let published = try await Post.where(Post.published == true).all(in: db)
    #expect(published.count == 3)

    let unpublished = try await Post.where(Post.published == false).count(in: db)
    #expect(unpublished == 1)

    // ORDER BY id DESC + LIMIT
    let top2 = try await Post.where(Post.published == true).order(by: Post.id, .descending).limit(2).all(in: db)
    #expect(top2.count == 2)
    #expect(top2[0].id > top2[1].id)

    // compound predicate (&&) with a Comparable column
    let compound = try await Post.where(Post.published == true && Post.id > 1).all(in: db)
    #expect(compound.count >= 1)
    #expect(compound.allSatisfy { $0.published && $0.id > 1 })

    // equality on text + all()
    let byTitle = try await Post.where(Post.title == "a").all(in: db)
    #expect(byTitle.count == 1)
    #expect(try await Post.count(in: db) == 4)
}

@Test func uuidPrimaryKeyCreateFindUpdateDeleteSQLite() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await APIAccessToken.createTable(in: db)

    let token = APIAccessToken(label: "primary")
    #expect(token.id != .zero)
    #expect(token.isPersisted == false)
    _ = try await token.save(in: db)
    #expect(token.isPersisted)

    let raw = try await db.query("SELECT id FROM api_access_tokens WHERE id = ?", [sqlUUID(token.id)])
    #expect(raw.rows.count == 1)
    if case .text(let stored) = raw.rows[0][0] {
        #expect(bytesEqual(stored, token.id.uuidString))
    } else {
        Issue.record("uuid id should be stored as text")
    }

    let found = try await APIAccessToken.find(token.id, in: db)
    #expect(found != nil)
    #expect(found!.id == token.id)
    #expect(bytesEqual(found!.label, "primary"))

    found!.label = "rotated"
    _ = try await found!.save(in: db)
    let reloaded = try await APIAccessToken.find(token.id, in: db)
    #expect(reloaded != nil && bytesEqual(reloaded!.label, "rotated"))

    try await reloaded!.delete(in: db)
    #expect(try await APIAccessToken.find(token.id, in: db) == nil)
}

// Model ⇄ JSON reuses the row codec.
@Test func modelJSONEncodeAndDecode() {
    let post = Post(title: "Hi", body: "b", published: true)
    let json = post.jsonObject()
    #expect(json["title"]?.stringValue == "Hi")
    #expect(json["published"]?.boolValue == true)
    #expect(json["id"]?.intValue == 0)

    let made = Post.fromJSON(parseJSON("{\"title\":\"New\",\"body\":\"x\",\"published\":false}")!)
    #expect(made.id == 0)                 // no id in JSON → insert-ready
    #expect(bytesEqual(made.title, "New"))
    #expect(made.published == false)
}

@Test func withinPredicateMatchesTheGivenSet() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Post.createTable(in: db)
    var ids: [Int] = []
    for index in 1...4 {
        let post = Post(title: "P\(index)", body: "", published: index % 2 == 0)
        _ = try await post.save(in: db)
        ids.append(post.id)
    }

    let picked = try await Post.where(Post.id.within([ids[0], ids[2]]))
        .order(by: Post.id).all(in: db)
    #expect(picked.map { $0.id } == [ids[0], ids[2]])

    // Composes with other predicates.
    let published = try await Post.where(Post.id.within(ids) && Post.published == true).all(in: db)
    #expect(published.count == 2)

    // An empty list matches nothing (and stays valid SQL).
    #expect(try await Post.where(Post.id.within([])).all(in: db).isEmpty)

    // Strings work too.
    let byTitle = try await Post.where(Post.title.within(["P1", "P4"])).all(in: db)
    #expect(byTitle.count == 2)
}

@Test func existsAndPluckQueries() async throws {
    let db = try NativeDrivers.sqlite(path: ":memory:")
    try await Post.createTable(in: db)
    for index in 1...3 {
        _ = try await Post(title: "P\(index)", body: "", published: index == 2).save(in: db)
    }

    #expect(try await Post.where(Post.published == true).exists(in: db))
    #expect(!(try await Post.where(Post.title == "missing").exists(in: db)))

    let ids = try await Post.where(Post.published == false).order(by: Post.id)
        .pluckInts(Post.id, in: db)
    #expect(ids.count == 2)
    #expect(ids == ids.sorted())
}
