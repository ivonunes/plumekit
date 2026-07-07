import Testing
@testable import PlumeCore

// Request-data validation over form and JSON bodies.

@Test func validatesUrlencodedFormInput() async {
    let app = Application()
    app.post("/signup") { request in
        let input = request.validate([
            ("email", [.required, .email]),
            ("age", [.required, .integer, .min(18)]),
        ])
        guard input.isValid else { return .json(input.errors.jsonValue, status: 422) }
        return .text("ok \(input.string("email")) \(input.int("age") ?? -1)")
    }
    let client = TestHTTPClient(app)

    let ok = await client.postForm("/signup", "email=a@b.com&age=21")
    #expect(ok.status == 200)
    #expect(ok.bodyText == "ok a@b.com 21")

    let bad = await client.postForm("/signup", "email=nope&age=10")
    #expect(bad.status == 422)
}

@Test func validatesJSONInput() async {
    let app = Application()
    app.post("/signup") { request in
        let input = request.validate([("email", [.required, .email])])
        return input.isValid ? .text("ok") : .json(input.errors.jsonValue, status: 422)
    }
    let client = TestHTTPClient(app)

    let ok = await client.post("/signup", json: .object([(name: "email", value: .string("a@b.com"))]))
    #expect(ok.status == 200)

    let bad = await client.post("/signup", json: .object([(name: "email", value: .string("bad"))]))
    #expect(bad.status == 422)
}

@Test func reportsPerFieldErrorsAndSkipsEmptyOptional() async {
    let app = Application()
    app.post("/x") { request in
        let input = request.validate([
            ("name", [.required]),
            ("nickname", [.minLength(3)]),        // optional: empty passes
            ("password", [.required, .minLength(8)]),
            ("confirm", [.sameAs("password")]),
        ])
        return .json(input.errors.jsonValue, status: input.isValid ? 200 : 422)
    }
    let client = TestHTTPClient(app)

    // name missing, password too short, confirm mismatch; nickname empty is fine
    let r = await client.postForm("/x", "password=short&confirm=nope")
    #expect(r.status == 422)
    let body = r.bodyText
    #expect(body.contains("name"))
    #expect(body.contains("is required"))
    #expect(!body.contains("nickname"))     // empty optional was skipped
}

@Test func validationDoesNotCrashOnOversizedNumericInput() async {
    let app = Application()
    app.post("/n") { request in
        let input = request.validate([("qty", [.integer, .min(1)])])
        return .text(input.isValid ? "ok" : "invalid")
    }
    let client = TestHTTPClient(app)
    // A 30-digit field overflows Int — must yield a validation result, not trap.
    let overflow = await client.postForm("/n", "qty=999999999999999999999999999999")
    #expect(overflow.status == 200)
    // A huge whole JSON double (Int64(d) would trap) — likewise handled.
    let bigDouble = await client.post("/n", json: .object([(name: "qty", value: .double(1e19))]))
    #expect(bigDouble.status == 200)
}
