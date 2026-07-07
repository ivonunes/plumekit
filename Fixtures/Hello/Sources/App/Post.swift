import PlumeORM

// ORM models. The Swift type is the source of truth; @Model reads it at compile
// time and emits schema + reflection-free codec + query columns + relationship
// handles — all Embedded-clean, so the same models run on the native server AND
// link into the Wasm worker.
@Model
final class Post: Model {
    var id: Int
    var title: String
    var views = 0
    var published = false
    var createdAt: Int64 = 0           // auto-managed by @Model on save (epoch ms)
    var updatedAt: Int64 = 0
    @HasMany var comments: [Comment]   // → Comment.post_id

    // Validations — run automatically by save(); closures, not keypaths.
    static let validations: [Validation<Post>] = [
        .presence("title") { $0.title },
        .length("title", max: 200) { $0.title },
        .atLeast("views", 0) { $0.views },
    ]
}

@Model
final class Comment: Model {
    var id: Int
    var body: String
    @BelongsTo var post: Post?         // → a `post_id` column
}
