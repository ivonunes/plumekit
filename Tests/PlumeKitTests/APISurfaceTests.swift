import Testing
@testable import PlumeCore

private actor MemKV {
    var data: [String: [UInt8]] = [:]
    func get(_ k: String) -> [UInt8]? { data[k] }
    func put(_ k: String, _ v: [UInt8]) { data[k] = v }
}

private func memKV() -> (KV, MemKV) {
    let store = MemKV()
    return (KV(get: { await store.get($0) }, put: { await store.put($0, $1) }), store)
}

@Test func apiErrorEnvelopeShape() {
    let response = APIError(status: 422, code: "validation_failed", message: "invalid",
                            fields: [(field: "title", message: "can't be blank")]).response()
    #expect(response.status == 422)
    let body = decodeUTF8(response.body)
    #expect(body.contains("\"code\":\"validation_failed\""))
    #expect(body.contains("\"field\":\"title\""))
    #expect(body.contains("\"message\":\"can't be blank\""))
}

@Test func paginatedEnvelopeShape() {
    let json = paginatedJSON([.object([("id", .int(1))])], limit: 20, offset: 0, hasMore: true)
    let body = decodeUTF8(json.serialize())
    #expect(body.contains("\"data\":[{\"id\":1}]"))
    #expect(body.contains("\"hasMore\":true"))
    #expect(body.contains("\"limit\":20"))
}

@Test func rateLimitCountsWithinWindowAndResetsAcross() async {
    let (kv, _) = memKV()
    // Same window (1200..1259 all map to window 1200/60 = 20) → monotonic count.
    #expect(await rateLimitHit(kv: kv, key: "k", windowSeconds: 60, now: 1200) == 1)
    #expect(await rateLimitHit(kv: kv, key: "k", windowSeconds: 60, now: 1230) == 2)
    #expect(await rateLimitHit(kv: kv, key: "k", windowSeconds: 60, now: 1259) == 3)
    // Next window (1260/60 = 21) → resets.
    #expect(await rateLimitHit(kv: kv, key: "k", windowSeconds: 60, now: 1260) == 1)
}

@Test func rateLimitMiddlewareReturns429PastLimit() async throws {
    let (kv, _) = memKV()
    let mw = rateLimit(prefix: "/api/", limit: 2, windowSeconds: 60, now: { 5000 })
    func hit() async throws -> Int {
        var req = Request(method: .get, path: "/api/x")
        req.context = Context(kv: kv)
        return try await mw(req) { _ in .text("ok") }.status
    }
    #expect(try await hit() == 200)   // 1
    #expect(try await hit() == 200)   // 2
    #expect(try await hit() == 429)   // 3 → over limit
}

@Test func requireAPITokenRejectsWithoutBearer() async throws {
    let mw = requireAPIToken(prefix: "/api/")
    // No bearer → 401.
    let anon = Request(method: .get, path: "/api/v1/posts")
    #expect(try await mw(anon) { _ in .text("ok") }.status == 401)
    // Bearer present + principal resolved → proceeds.
    var ok = Request(method: .get, path: "/api/v1/posts")
    ok.headers.add("authorization", "Bearer xyz")
    ok.principal = Principal(subject: "u1")
    #expect(try await mw(ok) { _ in .text("ok") }.status == 200)
    // Non-API path → always passes through.
    #expect(try await mw(Request(method: .get, path: "/")) { _ in .text("ok") }.status == 200)
}
