import Testing
@testable import PlumeCore

private struct PolicyDoc { let authorID: String }
private enum PolicyDocAction { case view, edit }

private struct PolicyDocPolicy: Policy {
    func can(_ principal: Principal?, _ action: PolicyDocAction, on doc: PolicyDoc) -> Bool {
        switch action {
        case .view: return true                                    // anyone may view
        case .edit: return principal?.is(doc.authorID) ?? false    // only the owner
        }
    }
}

private func authed(_ subject: String) -> Request {
    var r = Request(method: .get, path: "/")
    r.principal = Principal(subject: subject)
    return r
}

@Test func policyGatesHandlerFailClosed() {
    let policy = PolicyDocPolicy()
    let doc = PolicyDoc(authorID: "user-1")

    #expect(authed("user-1").authorize(policy, .edit, on: doc) == nil)              // owner → proceed
    #expect(authed("user-2").authorize(policy, .edit, on: doc)?.status == 403)      // non-owner → 403
    #expect(Request(method: .get, path: "/").authorize(policy, .edit, on: doc)?.status == 403)  // anon → fail closed
}

@Test func policyGatesViewFragment() {
    let policy = PolicyDocPolicy()
    let doc = PolicyDoc(authorID: "user-1")
    #expect(authed("user-1").allows(policy, .edit, on: doc))     // show edit affordance
    #expect(!authed("user-2").allows(policy, .edit, on: doc))    // hide it
    #expect(authed("user-2").allows(policy, .view, on: doc))     // everyone can view
}

@Test func requireAuthenticatedFailsClosed() {
    #expect(Request(method: .get, path: "/").requireAuthenticated()?.status == 401)
    #expect(authed("user-1").requireAuthenticated() == nil)
}
