import Foundation

// `plumekit generate notifications` — a two-channel notification scaffold: a
// `UserNotification` @Model (the in-app inbox) plus a `notify(...)` helper that
// writes the inbox row and, when the mailer capability is bound, also emails the
// user. One call, both channels, same code on every target.
func generateNotifications() -> Int32 {
    let files: [(path: String, label: String, contents: String)] = [
        ("Sources/App/Models/UserNotification.swift", "model", userNotificationModel),
        ("Sources/App/Support/Notify.swift", "support", notifySource),
    ]
    for file in files {
        if writeGenerated(file.contents, to: file.path, label: file.label) != 0 { return 1 }
    }

    let stamp = migrationTimestamp()
    let migration = #"""
    import PlumeORM

    let createUserNotifications = Migration(
        version: "\#(stamp)_create_user_notifications",
        up: { db in
            try await db.createTable("user_notifications") { t in
                t.id()
                t.references("user", table: "users")
                t.text("title")
                t.text("body")
                t.integer("read_at")
                t.integer("created_at")
            }
        },
        down: { db in try await db.dropTable("user_notifications") }
    )

    """#
    if writeGenerated(migration, to: "Sources/App/Database/Migrations/\(stamp)_CreateUserNotifications.swift", label: "migration") != 0 { return 1 }

    print("")
    print("  Notifications scaffold generated. To finish wiring it up:")
    print("")
    print("  1. Run `plumekit migrate` — the migration is picked up automatically.")
    print("  2. Notify from a handler or a job:")
    print("       try await notify(userID: user.id, email: user.email,")
    print("                        title: \"Payment received\", body: \"Invoice #42 was paid.\")")
    print("     The inbox is `UserNotification.for(userID)`; mark read with `markRead()`.")
    return 0
}

private let userNotificationModel = #"""
import PlumeORM

// An in-app notification (the "inbox" channel). `notify(...)` creates these; render
// them with `UserNotification.for(user.id)` and mark them read with `markRead()`.
@Model
final class UserNotification: Model {
    var id: Int
    var userId: Int
    var title: String
    var body: String
    var readAt = 0             // epoch seconds; 0 = unread
    var createdAt: Int64 = 0   // epoch millis — stamped automatically on save
}

extension UserNotification {
    /// The user's notifications, newest first.
    static func `for`(_ userID: Int, unreadOnly: Bool = false) async throws -> [UserNotification] {
        var query = UserNotification.where(UserNotification.userId == userID)
        if unreadOnly { query = query.where(UserNotification.readAt == 0) }
        return try await query.order(by: UserNotification.id, .descending).all()
    }

    func markRead() async throws {
        readAt = Int(ORMClock.now() / 1000)
        _ = try await save()
    }
}
"""#

private let notifySource = #"""
import PlumeCore
import PlumeORM

// Send a notification through every configured channel: always the in-app inbox
// (a UserNotification row), plus email when the mailer capability is bound.
//
//     try await notify(userID: user.id, email: user.email,
//                      title: "Payment received", body: "Invoice #42 was paid.")
//
// Pass `email: nil` to skip the email channel for this notification.
func notify(userID: Int, email: String?,
            title: String, body: String,
            from: String = "no-reply@example.com") async throws {
    let notification = UserNotification(userId: userID, title: title, body: body)
    _ = try await notification.save()

    if let email, let mailer = RequestContext.current?.mailer {
        try await mailer.send(EmailMessage(
            from: from, to: email, subject: title, textBody: body))
    }
}
"""#
