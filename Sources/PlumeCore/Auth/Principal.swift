// The authenticated identity carried across a request — the SAME shape whether
// it arrived via a signed cookie session or a bearer token. Deliberately minimal: a
// stable subject (the user id) plus the session id that carried it (for revocation).
// The app maps `subject` → its own User model; the auth layer never names that type.
public struct Principal: Sendable {
    public let subject: String
    public let sessionID: String     // the session/token id (jti) that authenticated it
    public init(subject: String, sessionID: String = "") {
        self.subject = subject
        self.sessionID = sessionID
    }
}
