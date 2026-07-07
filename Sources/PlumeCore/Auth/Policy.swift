import _Concurrency

// Authorization — a PLACE and a SHAPE, not a model. The framework ships the
// MECHANISM (a typed policy + fail-closed gates); the app defines its own actions,
// resources, and rules. No RBAC / ownership / per-tenant model is baked in — those
// are the app's to express in `can`. Independent of authentication and sessions.

/// A typed authorization policy. Conform a concrete type and decide. Fail closed:
/// `can` should return false unless a rule explicitly allows. Concrete (no
/// existential) so it stays Embedded-clean.
public protocol Policy: Sendable {
    associatedtype Action
    associatedtype Resource
    func can(_ principal: Principal?, _ action: Action, on resource: Resource) -> Bool
}

extension Request {
    /// Fail-closed authentication gate: 401 Response to return when there's no
    /// authenticated principal, or nil to proceed.
    public func requireAuthenticated() -> Response? {
        isAuthenticated ? nil : Response.text("401 Unauthorized", status: 401)
    }

    /// Fail-closed authorization gate: returns a 403 Response to return from the
    /// handler when the policy denies, or nil to proceed.
    public func authorize<P: Policy>(_ policy: P, _ action: P.Action, on resource: P.Resource) -> Response? {
        policy.can(principal, action, on: resource) ? nil : Response.text("403 Forbidden", status: 403)
    }

    /// Boolean form for gating a VIEW fragment:
    ///   `if request.allows(policy, .edit, on: post) { html.editButton() }`
    public func allows<P: Policy>(_ policy: P, _ action: P.Action, on resource: P.Resource) -> Bool {
        policy.can(principal, action, on: resource)
    }
}

extension Principal {
    /// Byte-wise subject equality — the common ownership check in
    /// a policy: `principal?.is(post.authorID) ?? false`. Works in the wasm guest.
    public func `is`(_ subject: String) -> Bool {
        Array(self.subject.utf8) == Array(subject.utf8)
    }
}
