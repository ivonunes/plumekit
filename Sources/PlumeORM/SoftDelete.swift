import PlumeCore

// Soft deletes — rows are hidden, not destroyed. Adopt by declaring the marker
// column and the conformance; every query then excludes trashed rows automatically
// (via the model's `defaultScope`), and `find` won't return them either:
//
//     @Model
//     final class Post: Model, SoftDeletable {
//         var id: Int
//         var title: String
//         var deletedAt = 0        // epoch seconds; 0 = live
//     }
//
//     try await post.softDelete()              // hide (sets deletedAt, keeps the row)
//     try await post.restore()                 // bring it back
//     try await post.forceDelete()             // actually DELETE the row
//     try await Post.all().all()               // live rows only
//     try await Post.withTrashed().all()       // everything
//     try await Post.onlyTrashed().all()       // just the hidden ones

public protocol SoftDeletable: Model {
    /// Epoch seconds when the row was soft-deleted; 0 means live.
    var deletedAt: Int { get set }
    /// The column backing `deletedAt`. Defaults to `deleted_at`; override if you
    /// rename it with `@Column`.
    static var deletedAtColumn: String { get }
}

extension SoftDeletable {
    public static var deletedAtColumn: String { "deleted_at" }

    /// Hides soft-deleted rows from every query (and from `find`). Bypass with
    /// `.unscoped()` / `withTrashed()`.
    public static var defaultScope: Predicate<Self>? {
        Column<Self, Int>(deletedAtColumn) == 0
    }

    /// Hide the row: stamps `deletedAt` and saves. The row stays in the table.
    /// (`max(1, …)` keeps the deleted *flag* correct even where no wall clock is
    /// installed — the timestamp is informative, the non-zero marker is semantic.)
    public func softDelete(in db: Database? = nil) async throws {
        deletedAt = max(1, Int(ORMClock.now() / 1000))
        _ = try await save(in: db)
    }

    /// Un-hide a soft-deleted row.
    public func restore(in db: Database? = nil) async throws {
        deletedAt = 0
        _ = try await save(in: db)
    }

    /// Really DELETE the row (what `delete()` does for any model).
    public func forceDelete(in db: Database? = nil) async throws {
        try await delete(in: db)
    }

    /// A query over every row, including soft-deleted ones.
    public static func withTrashed() -> Query<Self> {
        Query<Self>().unscoped()
    }

    /// A query over only the soft-deleted rows.
    public static func onlyTrashed() -> Query<Self> {
        Query<Self>().unscoped().where(Column<Self, Int>(deletedAtColumn) > 0)
    }
}
