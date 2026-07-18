import Foundation

// plumekit.toml is the single source of truth for Cloudflare configuration
// ([capabilities] + [targets.cloudflare]); wrangler.toml is a GENERATED build
// artifact emitted into the bundle so `wrangler dev`/`tail` and a manual
// `wrangler deploy` keep working. Settings plumekit doesn't model go in
// wrangler.extra.toml at the project root, appended to the artifact verbatim.
// A legacy user-owned wrangler.toml is absorbed into plumekit.toml once.

/// Which Cloudflare resources the app's manifest calls for.
struct CloudflareNeeds {
    var kv = false
    var cache = false
    var d1 = false
    var r2 = false
    var queue = false
}

/// Everything [targets.cloudflare] configures, with derived defaults filled in.
struct CloudflareSettings {
    var needs: CloudflareNeeds
    var name: String
    var accountId: String?
    var compatibilityDate: String
    var compatibilityFlags: [String]
    var kvId: String?
    var cacheId: String?
    var databaseName: String
    var databaseId: String?
    var bucketName: String
    var queueName: String
    var queueBatchSize: Int
    var queueBatchTimeout: Int
    var crons: [String]
    var domains: [String]
    var vars: [String: String]

    var snakeName: String { name.replacingOccurrences(of: "-", with: "_") }

    static func read(projectPath: String, projectName: String) -> CloudflareSettings {
        let manifest = parseManifest(projectPath: projectPath)
        let capabilities = manifest.sections["capabilities"] ?? [:]
        let cloudflare = manifest.sections["targets.cloudflare"] ?? [:]
        func enabled(_ name: String) -> Bool {
            capabilities.isEmpty ? true : capabilities[name] == "true"
        }
        var needs = CloudflareNeeds()
        needs.kv = enabled("kv")
        needs.cache = enabled("cache")
        needs.d1 = enabled("database") && (cloudflare["database"] ?? "d1") == "d1"
        needs.r2 = enabled("storage") && (cloudflare["storage"] ?? "r2") == "r2"
        needs.queue = enabled("queue")

        let name = cloudflare["name"] ?? projectName
        let snake = name.replacingOccurrences(of: "-", with: "_")
        return CloudflareSettings(
            needs: needs,
            name: name,
            accountId: cloudflare["account_id"],
            compatibilityDate: cloudflare["compatibility_date"] ?? "2026-06-01",
            compatibilityFlags: manifest.arrays["targets.cloudflare/compatibility_flags"] ?? [],
            kvId: cloudflare["kv_id"],
            cacheId: cloudflare["cache_id"],
            databaseName: cloudflare["database_name"] ?? "\(snake)_db",
            databaseId: cloudflare["database_id"],
            bucketName: cloudflare["bucket_name"] ?? "\(name)-blobs",
            queueName: cloudflare["queue_name"] ?? "\(name)-jobs",
            queueBatchSize: Int(cloudflare["queue_batch_size"] ?? "") ?? 10,
            queueBatchTimeout: Int(cloudflare["queue_batch_timeout"] ?? "") ?? 1,
            crons: manifest.arrays["targets.cloudflare/crons"] ?? [],
            domains: manifest.arrays["targets.cloudflare/domains"] ?? [],
            vars: manifest.sections["targets.cloudflare.vars"] ?? [:]
        )
    }
}

/// Line-oriented parse of plumekit.toml: scalar values per section, plus string
/// arrays keyed "section/key".
private func parseManifest(projectPath: String)
    -> (sections: [String: [String: String]], arrays: [String: [String]]) {
    var sections: [String: [String: String]] = [:]
    var arrays: [String: [String]] = [:]
    guard let toml = try? String(contentsOfFile: projectPath + "/plumekit.toml", encoding: .utf8) else {
        return (sections, arrays)
    }
    var section = ""
    for raw in toml.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("[") && line.hasSuffix("]") {
            section = String(line.dropFirst().dropLast())
            continue
        }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        var value = String(line[line.index(after: eq)...])
        var inQuote = false
        for index in value.indices {
            if value[index] == "\"" { inQuote.toggle() }
            else if value[index] == "#" && !inQuote { value = String(value[..<index]); break }
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            arrays["\(section)/\(key)"] = trimmed.dropFirst().dropLast()
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
                .filter { !$0.isEmpty }
        } else {
            sections[section, default: [:]][key] = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }
    return (sections, arrays)
}

// MARK: - Artifact generation

/// The wrangler.toml the bundle ships. Placeholder ids stand in until the first
/// deploy pins real ones (any string satisfies `wrangler dev`'s local simulator).
func generateWranglerToml(settings: CloudflareSettings, extra: String?) -> String {
    var out = """
    # Generated by `plumekit build` from plumekit.toml ([targets.cloudflare]).
    # Do not edit: set values there. Extra wrangler settings plumekit doesn't
    # model belong in wrangler.extra.toml at the project root (appended below).
    name = "\(settings.name)"
    main = "worker.mjs"
    compatibility_date = "\(settings.compatibilityDate)"

    """
    if let account = settings.accountId { out += "account_id = \"\(account)\"\n" }
    if !settings.compatibilityFlags.isEmpty {
        out += "compatibility_flags = [\(settings.compatibilityFlags.map { "\"\($0)\"" }.joined(separator: ", "))]\n"
    }
    out += """

    [assets]
    directory = "./public"

    """
    if settings.needs.kv {
        out += """

        [[kv_namespaces]]
        binding = "KV"
        id = "\(settings.kvId ?? "\(settings.snakeName)_kv_local")"

        """
    }
    if settings.needs.cache {
        out += """

        [[kv_namespaces]]
        binding = "CACHE"
        id = "\(settings.cacheId ?? "\(settings.snakeName)_cache_local")"

        """
    }
    if settings.needs.d1 {
        out += """

        [[d1_databases]]
        binding = "DB"
        database_name = "\(settings.databaseName)"
        database_id = "\(settings.databaseId ?? "\(settings.snakeName)_db_local_0000000000000000000000000000")"

        """
    }
    if settings.needs.r2 {
        out += """

        [[r2_buckets]]
        binding = "BLOB"
        bucket_name = "\(settings.bucketName)"

        """
    }
    if settings.needs.queue {
        out += """

        [[queues.producers]]
        binding = "QUEUE"
        queue = "\(settings.queueName)"

        [[queues.consumers]]
        queue = "\(settings.queueName)"
        max_batch_size = \(settings.queueBatchSize)
        max_batch_timeout = \(settings.queueBatchTimeout)

        """
    }
    // Channels ride in the runtime (worker.mjs always exports ChannelDO), so the
    // binding + migration are constant — declaring them is free if unused.
    out += """

    [[durable_objects.bindings]]
    name = "CHANNEL"
    class_name = "ChannelDO"

    [[migrations]]
    tag = "v1"
    new_sqlite_classes = ["ChannelDO"]

    """
    if !settings.crons.isEmpty {
        out += """

        [triggers]
        crons = [\(settings.crons.map { "\"\($0)\"" }.joined(separator: ", "))]

        """
    }
    if !settings.vars.isEmpty {
        out += "\n[vars]\n"
        for (key, value) in settings.vars.sorted(by: { $0.key < $1.key }) {
            out += "\(key) = \"\(value)\"\n"
        }
    }
    for domain in settings.domains {
        out += """

        [[routes]]
        pattern = "\(domain)"
        custom_domain = true

        """
    }
    if let extra, !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        out += "\n# --- wrangler.extra.toml (verbatim) ---\n" + extra
        if !extra.hasSuffix("\n") { out += "\n" }
    }
    return out
}

// MARK: - Legacy absorb

/// One-time migration: fold a user-owned root wrangler.toml into plumekit.toml's
/// [targets.cloudflare] and rename the file to wrangler.toml.bak. Anything that
/// doesn't map to a modeled setting is reported for wrangler.extra.toml.
func absorbLegacyWranglerToml(projectPath: String, projectName: String) {
    let legacyPath = projectPath + "/wrangler.toml"
    guard let legacy = WranglerConfig.load(legacyPath) else { return }

    // One-time means one-time: once [targets.cloudflare] carries more than the
    // driver keys the project is migrated, and a root wrangler.toml reappearing
    // (say, written by an older CLI) must not clobber the manifest or the backup.
    let cloudflareKeys = parseManifest(projectPath: projectPath).sections["targets.cloudflare"] ?? [:]
    if !cloudflareKeys.keys.filter({ $0 != "database" && $0 != "storage" }).isEmpty {
        errorLine("a root wrangler.toml exists but plumekit.toml already carries the Cloudflare "
                  + "config — ignoring it. Delete it (wrangler.toml is generated into the bundle now), "
                  + "or move unmodeled settings into wrangler.extra.toml.")
        return
    }

    var values: [(String, String)] = []
    func set(_ key: String, _ value: String) { values.append((key, "\"\(value)\"")) }
    func setRaw(_ key: String, _ value: String) { values.append((key, value)) }

    let name = legacy.name ?? projectName
    if name != projectName { set("name", name) }
    if let account = legacy.accountId { set("account_id", account) }
    if let date = legacy.compatibilityDate { set("compatibility_date", date) }
    if !legacy.compatibilityFlags.isEmpty {
        setRaw("compatibility_flags", "[\(legacy.compatibilityFlags.map { "\"\($0)\"" }.joined(separator: ", "))]")
    }
    let snake = name.replacingOccurrences(of: "-", with: "_")
    for kv in legacy.kvNamespaces where kv.id.count == 32 && kv.id.allSatisfy({ $0.isHexDigit }) {
        if kv.binding == "KV" { set("kv_id", kv.id) }
        if kv.binding == "CACHE" { set("cache_id", kv.id) }
    }
    if let d1 = legacy.d1Databases.first {
        if d1.databaseName != "\(snake)_db" { set("database_name", d1.databaseName) }
        if UUID(uuidString: d1.databaseId) != nil { set("database_id", d1.databaseId) }
    }
    if let r2 = legacy.r2Buckets.first, r2.bucketName != "\(name)-blobs" {
        set("bucket_name", r2.bucketName)
    }
    if let producer = legacy.queueProducers.first, producer.queue != "\(name)-jobs" {
        set("queue_name", producer.queue)
    }
    if let consumer = legacy.queueConsumers.first {
        if let size = consumer.maxBatchSize, size != 10 { setRaw("queue_batch_size", String(size)) }
        if let timeout = consumer.maxBatchTimeout, timeout != 1 { setRaw("queue_batch_timeout", String(timeout)) }
    }
    if !legacy.crons.isEmpty {
        setRaw("crons", "[\(legacy.crons.map { "\"\($0)\"" }.joined(separator: ", "))]")
    }
    let domains = legacy.routes.filter { $0.customDomain }.map { $0.pattern }
    if !domains.isEmpty {
        setRaw("domains", "[\(domains.map { "\"\($0)\"" }.joined(separator: ", "))]")
    }

    setManifestValues(projectToml: projectPath + "/plumekit.toml",
                      section: "targets.cloudflare", values: values)
    if !legacy.vars.isEmpty {
        setManifestValues(projectToml: projectPath + "/plumekit.toml",
                          section: "targets.cloudflare.vars",
                          values: legacy.vars.sorted(by: { $0.key < $1.key }).map { ($0.key, "\"\($0.value)\"") })
    }

    // What the model doesn't carry — the user moves these to wrangler.extra.toml.
    var unabsorbed: [String] = []
    for kv in legacy.kvNamespaces where kv.binding != "KV" && kv.binding != "CACHE" {
        unabsorbed.append("[[kv_namespaces]] binding \"\(kv.binding)\"")
    }
    if legacy.d1Databases.count > 1 { unabsorbed.append("additional [[d1_databases]]") }
    if legacy.r2Buckets.count > 1 { unabsorbed.append("additional [[r2_buckets]]") }
    if legacy.queueProducers.count > 1 { unabsorbed.append("additional [[queues.producers]]") }
    for route in legacy.routes where !route.customDomain {
        unabsorbed.append("[[routes]] \"\(route.pattern)\" (not a custom domain)")
    }
    for durable in legacy.durableObjects where durable.className != "ChannelDO" {
        unabsorbed.append("[[durable_objects.bindings]] \(durable.name) → \(durable.className)")
    }

    try? FileManager.default.moveItem(atPath: legacyPath, toPath: legacyPath + ".bak")
    print("  absorbed wrangler.toml into plumekit.toml ([targets.cloudflare]); the old file")
    print("  is now wrangler.toml.bak — wrangler.toml is a generated build artifact from here on.")
    for entry in unabsorbed {
        errorLine("  not absorbed: \(entry) — move it to wrangler.extra.toml (appended to the artifact verbatim)")
    }
}

// MARK: - Manifest writeback

/// Set keys in a plumekit.toml section, replacing existing lines or appending to
/// the section (created at the end of the file when missing). `value` is written
/// raw — callers quote strings themselves. Everything else is preserved.
func setManifestValues(projectToml: String, section: String, values: [(key: String, value: String)]) {
    guard !values.isEmpty,
          let contents = try? String(contentsOfFile: projectToml, encoding: .utf8) else { return }
    var lines = contents.components(separatedBy: "\n")

    var sectionHeader = -1
    var sectionEnd = -1
    var index = 0
    while index < lines.count {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        if trimmed == "[\(section)]" {
            sectionHeader = index
        } else if sectionHeader >= 0, sectionEnd < 0, trimmed.hasPrefix("[") {
            sectionEnd = index
        }
        index += 1
    }
    if sectionHeader < 0 {
        if lines.last == "" { lines.removeLast() }
        lines += ["", "[\(section)]"]
        sectionHeader = lines.count - 1
    }
    if sectionEnd < 0 { sectionEnd = lines.count }

    for (key, value) in values {
        var replaced = false
        for lineIndex in (sectionHeader + 1)..<sectionEnd {
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            if trimmed[..<eq].trimmingCharacters(in: .whitespaces) == key {
                lines[lineIndex] = "\(key) = \(value)"
                replaced = true
                break
            }
        }
        if !replaced {
            // Insert right after the section's last key line (comments that lead
            // into the NEXT section stay below the inserted keys).
            var insertAt = sectionHeader + 1
            for lineIndex in (sectionHeader + 1)..<sectionEnd {
                let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") { insertAt = lineIndex + 1 }
            }
            lines.insert("\(key) = \(value)", at: insertAt)
            sectionEnd += 1
        }
    }

    let updated = lines.joined(separator: "\n")
    if updated != contents {
        try? updated.write(toFile: projectToml, atomically: true, encoding: .utf8)
    }
}

/// Pin one [targets.cloudflare] value (used by provisioning for fresh ids).
func pinManifestValue(projectPath: String, key: String, value: String) {
    setManifestValues(projectToml: projectPath + "/plumekit.toml",
                      section: "targets.cloudflare", values: [(key, "\"\(value)\"")])
}
