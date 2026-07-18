import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Cloudflare auth for the API-only deploy path. A bearer token is resolved from,
// in order: the CLOUDFLARE_API_TOKEN env var, the token stored by `plumekit
// login`, and an UNEXPIRED wrangler OAuth session (adopted read-only — its
// refresh flow belongs to wrangler's own OAuth client, and consuming a rotating
// refresh token could invalidate the user's wrangler login, so an expired
// session is treated as absent).

/// The bearer token to use, if any source has one.
func cloudflareToken() -> String? {
    if let env = ProcessInfo.processInfo.environment["CLOUDFLARE_API_TOKEN"], !env.isEmpty { return env }
    if let stored = storedCredentials()?.token { return stored }
    return wranglerSessionToken()
}

/// The account id fallback from `plumekit login` (env and plumekit.toml win).
func storedAccountId() -> String? {
    storedCredentials()?.accountId
}

// MARK: - plumekit's own credential store

private func credentialsPath() -> String {
    let env = ProcessInfo.processInfo.environment
    let configHome = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        ?? NSHomeDirectory() + "/.config"
    return configHome + "/plumekit/credentials.toml"
}

/// The credentials file is sectioned by provider ([cloudflare] today) so future
/// targets slot in without a format migration.
private func storedCredentials() -> (token: String?, accountId: String?)? {
    guard let toml = try? String(contentsOfFile: credentialsPath(), encoding: .utf8) else { return nil }
    var section = ""
    var token: String?
    var account: String?
    for line in toml.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            section = String(trimmed.dropFirst().dropLast())
            continue
        }
        guard section == "cloudflare", let eq = trimmed.firstIndex(of: "=") else { continue }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: eq)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        if key == "api_token", !value.isEmpty { token = value }
        if key == "account_id", !value.isEmpty { account = value }
    }
    return (token == nil && account == nil) ? nil : (token, account)
}

func storeCredentials(token: String, accountId: String?) -> Bool {
    let path = credentialsPath()
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var toml = "# Written by `plumekit login`.\n[cloudflare]\napi_token = \"\(token)\"\n"
    if let accountId { toml += "account_id = \"\(accountId)\"\n" }
    guard (try? toml.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return false }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    return true
}

func removeCredentials() -> Bool {
    let path = credentialsPath()
    guard FileManager.default.fileExists(atPath: path) else { return false }
    return (try? FileManager.default.removeItem(atPath: path)) != nil
}

// MARK: - wrangler session adoption

/// The oauth_token from wrangler's config, when a config exists and the session
/// hasn't expired. Legacy configs carry a plain api_token instead — also used.
private func wranglerSessionToken() -> String? {
    let home = NSHomeDirectory()
    let env = ProcessInfo.processInfo.environment
    var candidates: [String] = []
    if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty { candidates.append(xdg + "/.wrangler/config/default.toml") }
    candidates += [
        home + "/.config/.wrangler/config/default.toml",
        home + "/Library/Preferences/.wrangler/config/default.toml",
        home + "/.wrangler/config/default.toml",
    ]
    for path in candidates {
        guard let toml = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        var values: [String: String] = [:]
        for line in toml.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            values[key] = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        if let legacy = values["api_token"], !legacy.isEmpty { return legacy }
        guard let token = values["oauth_token"], !token.isEmpty else { continue }
        guard let expiry = values["expiration_time"],
              let expires = parseISO8601(expiry),
              expires > Date().addingTimeInterval(30) else { continue }
        return token
    }
    return nil
}

private func parseISO8601(_ text: String) -> Date? {
    let plain = ISO8601DateFormatter()
    if let date = plain.date(from: text) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text)
}

// MARK: - token creation

/// The dashboard's create-token page, pre-filled with exactly the permissions
/// plumekit deploys need (the "Edit Cloudflare Workers" template lacks D1 and
/// more). The page shows the selection before creating, so nothing is hidden.
func cloudflareTokenURL(name: String) -> String {
    let groups = [
        ("workers_scripts", "edit"),      // module upload, settings, secrets
        ("workers_kv_storage", "edit"),   // KV namespaces (+ provisioning)
        ("workers_r2", "edit"),           // R2 buckets (+ provisioning)
        ("d1", "edit"),                   // migrations over the D1 API
        ("queues", "edit"),               // queue + consumer provisioning
        ("workers_routes", "edit"),       // custom-domain routes
        ("zone", "read"),                 // zone lookup for custom domains
    ]
    let keys = "[" + groups.map { "{\"key\":\"\($0.0)\",\"type\":\"\($0.1)\"}" }
        .joined(separator: ",") + "]"
    var components = URLComponents(string: "https://dash.cloudflare.com/profile/api-tokens")!
    components.queryItems = [
        URLQueryItem(name: "permissionGroupKeys", value: keys),
        URLQueryItem(name: "name", value: name),
    ]
    return components.url!.absoluteString
}

/// `plumekit token [provider]` — the easiest way to mint deploy credentials:
/// prints (and opens, when interactive) the pre-filled token page, then says
/// where the token goes for CI.
func tokenCommand(arguments: [String]) -> Int32 {
    let provider = arguments.first ?? defaultProvider()
    guard provider == "cloudflare" else {
        errorLine("no token flow for target \"\(provider)\" (supported: cloudflare)")
        return 1
    }
    let app = CloudflareSettings.read(projectPath: ".", projectName: "plumekit").name
    let url = cloudflareTokenURL(name: "\(app) deploys")
    print("Create the deploy token here (permissions pre-selected — scope it to the")
    print("account, review, and create):")
    print("")
    print("  \(url)")
    print("")
    print("Then either store it for local deploys:   plumekit login")
    print("or add it to CI:                          gh secret set CLOUDFLARE_API_TOKEN")
    if isatty(STDOUT_FILENO) != 0 {
        #if os(macOS)
        _ = capture("open", [url])
        #else
        _ = capture("xdg-open", [url])
        #endif
    }
    return 0
}

// MARK: - login / logout

// plumekit is target-generic: `login [provider]` defaults to the app's default
// target and dispatches per provider. Only cloudflare has a credential store
// today; providers with their own credential chains get pointed at them.

/// The provider a bare `login`/`secret` command should act on.
func defaultProvider(path: String = ".") -> String {
    let config = BuildConfig.read(projectPath: path)
    return config.defaultTarget ?? config.targets.first ?? "cloudflare"
}

func loginCommand(arguments: [String]) -> Int32 {
    let provider = arguments.first ?? defaultProvider()
    switch provider {
    case "cloudflare": return cloudflareLogin()
    case "aws":
        errorLine("aws uses its own credential chain (env vars, ~/.aws profiles) — nothing for plumekit to store.")
        return 1
    default:
        errorLine("no login for target \"\(provider)\" (supported: cloudflare)")
        return 1
    }
}

func logoutCommand(arguments: [String]) -> Int32 {
    let provider = arguments.first ?? defaultProvider()
    guard provider == "cloudflare" else {
        errorLine("no stored credentials for target \"\(provider)\"")
        return 1
    }
    if removeCredentials() {
        print(Style.green("✓") + " Logged out")
    } else {
        print("No stored credentials.")
    }
    return 0
}

private func cloudflareLogin() -> Int32 {
    print("Create an API token with the pre-filled permissions plumekit needs:")
    print("  \(cloudflareTokenURL(name: "plumekit deploys"))")
    guard let token = readSecretValue(prompt: "API token (hidden): "),
          !token.trimmingCharacters(in: .whitespaces).isEmpty else {
        errorLine("no token given")
        return 1
    }
    let cleaned = token.trimmingCharacters(in: .whitespaces)
    let probe = CloudflareAPI(accountId: "", token: cleaned)
    guard probe.call("GET", "/user/tokens/verify", quietErrors: true) != nil else {
        errorLine("Cloudflare rejected the token (GET /user/tokens/verify failed) — nothing stored.")
        return 1
    }
    var accountId: String?
    if let accounts = probe.call("GET", "/accounts?per_page=25", quietErrors: true) as? [[String: Any]] {
        let named = accounts.compactMap { account -> (id: String, name: String)? in
            guard let id = account["id"] as? String else { return nil }
            return (id, (account["name"] as? String) ?? id)
        }
        if named.count == 1 {
            accountId = named[0].id
        } else if named.count > 1 {
            let choice = Prompt.select("Default account", named.map { $0.name })
            accountId = named[choice].id
        }
    }
    guard storeCredentials(token: cleaned, accountId: accountId) else {
        errorLine("could not write the credentials file")
        return 1
    }
    print(Style.green("✓") + " Logged in" + (accountId.map { " (account \($0))" } ?? ""))
    return 0
}

