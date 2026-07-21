import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A minimal Cloudflare v4 API client, so `plumekit deploy`/`migrate` need no
// wrangler (and therefore no Node). Synchronous like the rest of the CLI.
// Auth comes from cloudflareToken() (env var, `plumekit login`, or an adopted
// wrangler session — see CloudflareAuth.swift).
struct CloudflareAPI {
    let accountId: String
    let token: String
    private let base = "https://api.cloudflare.com/client/v4"

    /// The client when any auth source yields a token (see cloudflareToken()).
    /// Account id precedence: CLOUDFLARE_ACCOUNT_ID env var, then the configured
    /// value, then the `plumekit login` store's default.
    static func resolve(accountId configured: String?) -> CloudflareAPI? {
        guard let token = cloudflareToken() else { return nil }
        let env = ProcessInfo.processInfo.environment
        let account = [env["CLOUDFLARE_ACCOUNT_ID"], configured, storedAccountId()]
            .compactMap { $0 }.first { !$0.isEmpty }
        guard let account else { return nil }
        return CloudflareAPI(accountId: account, token: token)
    }

    static func resolve(config: WranglerConfig) -> CloudflareAPI? {
        resolve(accountId: config.accountId)
    }

    // MARK: - Core request plumbing

    /// One API call. Returns the envelope's `result` on success; on failure prints
    /// the API's error messages and returns nil. `bearer` overrides the account API
    /// token (the assets upload endpoints authenticate with per-session JWTs).
    @discardableResult
    func call(_ method: String, _ path: String, contentType: String? = nil, body: Data? = nil,
              bearer: String? = nil, quietErrors: Bool = false) -> Any? {
        callDetailed(method, path, contentType: contentType, body: body,
                     bearer: bearer, quietErrors: quietErrors).result
    }

    /// Like call(), but also hands back the API's error text so callers can react
    /// to specific failures.
    func callDetailed(_ method: String, _ path: String, contentType: String? = nil, body: Data? = nil,
                      bearer: String? = nil, quietErrors: Bool = false) -> (result: Any?, error: String?) {
        guard let url = URL(string: base + path) else { return (nil, "bad URL") }
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = method
        request.setValue("Bearer \(bearer ?? token)", forHTTPHeaderField: "Authorization")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body

        let done = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            box.payload = data
            box.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.transportError = error.map { "\($0)" }
        }.resume()
        done.wait()
        let (payload, status, transportError) = (box.payload, box.status, box.transportError)

        if let transportError {
            if !quietErrors { errorLine("Cloudflare API request failed (\(method) \(path)): \(transportError)") }
            return (nil, transportError)
        }
        let json = payload.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let success = (json?["success"] as? Bool) ?? false
        guard (200...299).contains(status), success else {
            let messages = ((json?["errors"] as? [[String: Any]]) ?? [])
                .compactMap { $0["message"] as? String }
            let message = messages.isEmpty ? "unknown error" : messages.joined(separator: "; ")
            if !quietErrors {
                errorLine("Cloudflare API error (\(method) \(path), HTTP \(status)): " + message)
            }
            return (nil, message)
        }
        return (json?["result"] ?? [:] as [String: Any], nil)
    }

    /// Every item of a list endpoint, paging until it runs out.
    ///
    /// `page` is a REQUEST, not a promise. Several Cloudflare list endpoints (the
    /// worker scripts list and the durable-object namespaces list among them) ignore
    /// it and return the whole collection every time — so a loop that stops only on
    /// an empty page never stops, and hammers the API forever at one request per
    /// iteration. Two independent brakes: a short page is the last page (ordinary
    /// pagination), and a page identical to the one before it means the endpoint is
    /// not paging at all.
    func listAll(_ path: String, perPage: Int = 100) -> [[String: Any]] {
        let join = path.contains("?") ? "&" : "?"
        var out: [[String: Any]] = []
        var previous: String?
        var page = 1
        while page <= 100 {
            guard let items = call("GET", "\(path)\(join)per_page=\(perPage)&page=\(page)",
                                   quietErrors: true) as? [[String: Any]], !items.isEmpty else { break }
            let signature = items
                .map { String(describing: $0["id"] ?? $0["name"] ?? $0["queue_name"] ?? $0["title"] ?? "") }
                .joined(separator: ",")
            if signature == previous { break }
            previous = signature
            out += items
            if items.count < perPage { break }
            page += 1
        }
        return out
    }

    func callJSON(_ method: String, _ path: String, json object: Any, bearer: String? = nil,
                  quietErrors: Bool = false) -> Any? {
        guard let body = try? JSONSerialization.data(withJSONObject: object) else {
            if !quietErrors { errorLine("could not encode the request body for \(method) \(path)") }
            return nil
        }
        return call(method, path, contentType: "application/json", body: body,
                    bearer: bearer, quietErrors: quietErrors)
    }

    // MARK: - Endpoints

    /// The deployed script's current durable-object migration tag, nil when the
    /// script doesn't exist yet (first deploy) or has no migrations. The service
    /// metadata endpoint carries it (the same place wrangler reads it from); the
    /// scripts list is the fallback.
    func scriptMigrationTag(script: String) -> String? {
        if let service = call("GET", "/accounts/\(accountId)/workers/services/\(script)",
                              quietErrors: true) as? [String: Any],
           let environment = service["default_environment"] as? [String: Any],
           let scriptInfo = environment["script"] as? [String: Any],
           let tag = scriptInfo["migration_tag"] as? String, !tag.isEmpty {
            return tag
        }
        let scripts = listAll("/accounts/\(accountId)/workers/scripts")
        if let match = scripts.first(where: { ($0["id"] as? String) == script }),
           let tag = match["migration_tag"] as? String, !tag.isEmpty {
            return tag
        }
        return nil
    }

    /// The durable-object classes that already have live namespaces on this script —
    /// the ground truth for "has this class been migrated", independent of tags.
    func durableObjectClasses(script: String) -> Set<String> {
        var classes: Set<String> = []
        let namespaces = listAll("/accounts/\(accountId)/workers/durable_objects/namespaces")
        for namespace in namespaces where (namespace["script"] as? String) == script {
            if let className = namespace["class"] as? String { classes.insert(className) }
        }
        return classes
    }

    func startAssetsUploadSession(script: String, manifest: [String: Any]) -> (jwt: String, buckets: [[String]])? {
        guard let result = callJSON("POST", "/accounts/\(accountId)/workers/scripts/\(script)/assets-upload-session",
                                    json: ["manifest": manifest]) as? [String: Any],
              let jwt = result["jwt"] as? String else { return nil }
        return (jwt, (result["buckets"] as? [[String]]) ?? [])
    }

    /// Upload one bucket of assets; returns the response's completion JWT if present
    /// (the final bucket's response carries it).
    func uploadAssetBucket(form: MultipartForm, sessionJWT: String) -> String? {
        let result = call("POST", "/accounts/\(accountId)/workers/assets/upload?base64=true",
                          contentType: form.contentType, body: form.body(), bearer: sessionJWT)
        return (result as? [String: Any])?["jwt"] as? String
    }

    /// Upload the script; on failure the API's error text comes back so the deploy
    /// can react (e.g. the migrations-already-applied case).
    func uploadScript(script: String, form: MultipartForm, quietErrors: Bool = false) -> (ok: Bool, error: String?) {
        let outcome = callDetailed("PUT", "/accounts/\(accountId)/workers/scripts/\(script)",
                                   contentType: form.contentType, body: form.body(),
                                   quietErrors: quietErrors)
        return (outcome.result != nil, outcome.error)
    }

    func putSchedules(script: String, crons: [String]) -> Bool {
        callJSON("PUT", "/accounts/\(accountId)/workers/scripts/\(script)/schedules",
                 json: crons.map { ["cron": $0] }) != nil
    }

    func listSecrets(script: String) -> [String]? {
        guard let result = call("GET", "/accounts/\(accountId)/workers/scripts/\(script)/secrets",
                                quietErrors: true) as? [[String: Any]] else { return nil }
        return result.compactMap { $0["name"] as? String }
    }

    func queueId(name: String) -> String? {
        let queues = listAll("/accounts/\(accountId)/queues")
        if let match = queues.first(where: { ($0["queue_name"] as? String) == name }) {
            return (match["queue_id"] as? String) ?? (match["id"] as? String)
        }
        return nil
    }

    /// Attach (or update) the worker as the queue's consumer.
    func ensureQueueConsumer(queueId: String, script: String, settings: [String: Any]) -> Bool {
        var consumer: [String: Any] = ["type": "worker", "script_name": script]
        if !settings.isEmpty { consumer["settings"] = settings }
        let existing = call("GET", "/accounts/\(accountId)/queues/\(queueId)/consumers",
                            quietErrors: true) as? [[String: Any]]
        let ours = existing?.first {
            (($0["script"] as? String) ?? ($0["script_name"] as? String)) == script
        }
        if let consumerId = (ours?["consumer_id"] as? String) ?? (ours?["id"] as? String) {
            return callJSON("PUT", "/accounts/\(accountId)/queues/\(queueId)/consumers/\(consumerId)",
                            json: consumer) != nil
        }
        return callJSON("POST", "/accounts/\(accountId)/queues/\(queueId)/consumers", json: consumer) != nil
    }

    /// The account zone containing `hostname`, walking up its labels
    /// (app.waytera.com → waytera.com). Needs the token's Zone read permission.
    func findZone(forHost hostname: String) -> String? {
        var labels = hostname.split(separator: ".").map(String.init)
        while labels.count >= 2 {
            let candidate = labels.joined(separator: ".")
            if let zones = call("GET", "/zones?name=\(candidate)", quietErrors: true) as? [[String: Any]],
               zones.contains(where: { ($0["name"] as? String) == candidate }) {
                return candidate
            }
            labels.removeFirst()
        }
        return nil
    }

    /// Attach a custom domain to the worker (idempotent on Cloudflare's side).
    func putCustomDomain(hostname: String, zoneName: String?, script: String) -> Bool {
        var body: [String: Any] = ["environment": "production", "hostname": hostname, "service": script]
        if let zoneName { body["zone_name"] = zoneName }
        return callJSON("PUT", "/accounts/\(accountId)/workers/domains", json: body) != nil
    }

    /// Run SQL against a D1 database. Returns the per-statement result objects.
    func d1Query(databaseId: String, sql: String) -> [[String: Any]]? {
        let result = callJSON("POST", "/accounts/\(accountId)/d1/database/\(databaseId)/query",
                              json: ["sql": sql])
        // A successful call whose `result` isn't the expected array used to fall
        // out of an `as?` as a bare nil, leaving the caller to fail with nothing
        // to report. Say what came back instead.
        guard let result else { return nil }
        guard let rows = result as? [[String: Any]] else {
            errorLine("D1 query succeeded but returned an unexpected result shape "
                      + "(\(type(of: result))): \(String(describing: result).prefix(300))")
            return nil
        }
        return rows
    }

    // MARK: - Provisioning lookups & creates

    /// Ids of KV namespaces with exactly this title. More than one means the title
    /// is ambiguous (Cloudflare doesn't enforce unique titles) — callers must not guess.
    func findKVNamespaces(title: String) -> [String] {
        let namespaces = listAll("/accounts/\(accountId)/storage/kv/namespaces")
        return namespaces
            .filter { ($0["title"] as? String) == title }
            .compactMap { $0["id"] as? String }
    }

    func createKVNamespace(title: String) -> String? {
        (callJSON("POST", "/accounts/\(accountId)/storage/kv/namespaces",
                  json: ["title": title]) as? [String: Any])?["id"] as? String
    }

    /// The uuid of the D1 database with exactly this name (names are unique per account).
    func findD1Database(name: String) -> String? {
        guard let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let databases = call("GET", "/accounts/\(accountId)/d1/database?name=\(escaped)",
                                   quietErrors: true) as? [[String: Any]] else { return nil }
        return databases.first { ($0["name"] as? String) == name }?["uuid"] as? String
    }

    func createD1Database(name: String) -> String? {
        (callJSON("POST", "/accounts/\(accountId)/d1/database",
                  json: ["name": name]) as? [String: Any])?["uuid"] as? String
    }

    func r2BucketExists(name: String) -> Bool {
        call("GET", "/accounts/\(accountId)/r2/buckets/\(name)", quietErrors: true) != nil
    }

    func createR2Bucket(name: String) -> Bool {
        callJSON("POST", "/accounts/\(accountId)/r2/buckets", json: ["name": name]) != nil
    }

    func createQueue(name: String) -> String? {
        let result = callJSON("POST", "/accounts/\(accountId)/queues",
                              json: ["queue_name": name]) as? [String: Any]
        return (result?["queue_id"] as? String) ?? (result?["id"] as? String)
    }

    func putSecret(script: String, name: String, value: String) -> Bool {
        callJSON("PUT", "/accounts/\(accountId)/workers/scripts/\(script)/secrets",
                 json: ["name": name, "text": value, "type": "secret_text"]) != nil
    }
}

/// Result carrier for the synchronous URLSession bridge — written once before the
/// semaphore signals, read after it waits, so access is ordered.
private final class ResponseBox: @unchecked Sendable {
    var payload: Data?
    var status = 0
    var transportError: String?
}

// MARK: - Multipart

/// A hand-rolled multipart/form-data body (the script and asset upload endpoints
/// take multipart, and this beats pulling in a dependency for two call sites).
struct MultipartForm {
    private let boundary = "plumekit-" + UUID().uuidString
    private var parts: [Data] = []

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String, contentType: String? = nil) {
        var head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        parts.append(Data((head + "\r\n" + value + "\r\n").utf8))
    }

    mutating func addFile(name: String, filename: String, mimeType: String, bytes: Data) {
        let head = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                 + "Content-Type: \(mimeType)\r\n\r\n"
        var part = Data(head.utf8)
        part.append(bytes)
        part.append(Data("\r\n".utf8))
        parts.append(part)
    }

    func body() -> Data {
        var data = Data()
        for part in parts { data.append(part) }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }
}
