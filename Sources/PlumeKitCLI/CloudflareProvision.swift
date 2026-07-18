import Foundation

// Resolve-or-create the Cloudflare resources the config declares, so a fresh
// scaffold deploys from zero with nothing but auth. Pinned ids are a convenience,
// not a requirement: a missing/placeholder id is resolved by name on every run
// (idempotent), created when absent, and pinned into plumekit.toml's
// [targets.cloudflare] (kv_id / cache_id / database_id) plus the generated bundle
// artifact — in CI the writeback simply evaporates and by-name resolution keeps
// working, so nothing needs to commit from CI. Strictly create-and-adopt: only
// declared resources, never a delete or rename.

/// Provision everything the config needs for a deploy. Returns the config with
/// real ids filled in, or nil when something couldn't be resolved.
func provisionCloudflareResources(config: WranglerConfig, api: CloudflareAPI,
                                  projectRoot: String, bundleToml: String) -> WranglerConfig? {
    var config = config
    let worker = config.name ?? "app"

    for index in config.kvNamespaces.indices {
        let namespace = config.kvNamespaces[index]
        guard !isKVNamespaceId(namespace.id) else { continue }
        // Same title convention wrangler's `kv namespace create` uses.
        let title = "\(worker)-\(namespace.binding)"
        let existing = api.findKVNamespaces(title: title)
        let id: String
        switch existing.count {
        case 0:
            guard let created = api.createKVNamespace(title: title) else { return nil }
            id = created
            print("  provisioned   KV namespace \"\(title)\" (\(namespace.binding))")
        case 1:
            id = existing[0]
            print("  adopted       KV namespace \"\(title)\" (\(namespace.binding))")
        default:
            errorLine("several KV namespaces are titled \"\(title)\" — pin the right one in "
                      + "plumekit.toml ([targets.cloudflare] \(namespace.binding == "CACHE" ? "cache_id" : "kv_id"))")
            return nil
        }
        config.kvNamespaces[index].id = id
        switch namespace.binding {
        case "KV": pinManifestValue(projectPath: projectRoot, key: "kv_id", value: id)
        case "CACHE": pinManifestValue(projectPath: projectRoot, key: "cache_id", value: id)
        default:
            // Extra namespaces come from wrangler.extra.toml — the user owns that id.
            print("  note: pin id \"\(id)\" for binding \"\(namespace.binding)\" in wrangler.extra.toml")
        }
        pinWranglerValue(section: "kv_namespaces", matchKey: "binding", matchValue: namespace.binding,
                         key: "id", value: id, in: [bundleToml])
    }

    for index in config.d1Databases.indices {
        let database = config.d1Databases[index]
        guard UUID(uuidString: database.databaseId) == nil else { continue }
        guard let id = resolveOrCreateD1(api: api, name: database.databaseName) else { return nil }
        config.d1Databases[index].databaseId = id
        if index == 0 { pinManifestValue(projectPath: projectRoot, key: "database_id", value: id) }
        pinWranglerValue(section: "d1_databases", matchKey: "database_name", matchValue: database.databaseName,
                         key: "database_id", value: id, in: [bundleToml])
    }

    for bucket in config.r2Buckets where !api.r2BucketExists(name: bucket.bucketName) {
        guard api.createR2Bucket(name: bucket.bucketName) else { return nil }
        print("  provisioned   R2 bucket \"\(bucket.bucketName)\" (\(bucket.binding))")
    }

    let queues = Set(config.queueProducers.map { $0.queue } + config.queueConsumers.map { $0.queue })
    for queue in queues.sorted() where api.queueId(name: queue) == nil {
        guard api.createQueue(name: queue) != nil else { return nil }
        print("  provisioned   queue \"\(queue)\"")
    }

    return config
}

/// The remote D1 to target: the pinned database_id when it's a real uuid, else
/// resolve by name (creating on first use) and pin it back. Shared by migrate,
/// seed and deploy so whichever runs first provisions the database.
func ensureRemoteD1(api: CloudflareAPI, config: WranglerConfig, dbName: String?,
                    projectRoot: String, bundleToml: String) -> String? {
    let entry = config.d1Databases.first(where: { dbName == nil || $0.databaseName == dbName })
        ?? config.d1Databases.first
    guard let entry, !entry.databaseName.isEmpty else { return nil }
    if UUID(uuidString: entry.databaseId) != nil { return entry.databaseId }
    guard let id = resolveOrCreateD1(api: api, name: entry.databaseName) else { return nil }
    pinManifestValue(projectPath: projectRoot, key: "database_id", value: id)
    pinWranglerValue(section: "d1_databases", matchKey: "database_name", matchValue: entry.databaseName,
                     key: "database_id", value: id, in: [bundleToml])
    return id
}

/// The transport for a remote-D1 command. `.none` means no auth source yielded a
/// token — callers report how to authenticate. `.failed` means auth exists but the
/// database can't be resolved or created.
enum RemoteD1Transport {
    case none
    case failed
    case api(CloudflareAPI, databaseId: String)
}

func remoteD1Transport(projectPath: String, bundleToml: String, dbName: String?) -> RemoteD1Transport {
    guard let config = WranglerConfig.load(bundleToml),
          let api = CloudflareAPI.resolve(config: config) else { return .none }
    guard let id = ensureRemoteD1(api: api, config: config, dbName: dbName,
                                  projectRoot: projectPath, bundleToml: bundleToml) else { return .failed }
    return .api(api, databaseId: id)
}

private func resolveOrCreateD1(api: CloudflareAPI, name: String) -> String? {
    if let existing = api.findD1Database(name: name) {
        print("  adopted       D1 database \"\(name)\"")
        return existing
    }
    guard let created = api.createD1Database(name: name) else { return nil }
    print("  provisioned   D1 database \"\(name)\"")
    return created
}

/// A plausible real KV namespace id (32 hex chars) — the scaffold's local
/// placeholders and empty values fail this and trigger provisioning.
private func isKVNamespaceId(_ id: String) -> Bool {
    id.count == 32 && id.allSatisfy { $0.isHexDigit }
}

// MARK: - wrangler.toml writeback

/// Pin `key = "value"` inside the [[section]] block whose `matchKey` equals
/// `matchValue`, replacing the block's existing `key` line or inserting one after
/// the match line. Every other byte of the file is preserved (the file is
/// user-owned and carries their comments). Missing/unwritable files are skipped —
/// the pin is a convenience, resolution by name keeps working without it.
func pinWranglerValue(section: String, matchKey: String, matchValue: String,
                      key: String, value: String, in files: [String]) {
    for file in files {
        guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
        var lines = contents.components(separatedBy: "\n")
        var inTargetBlock = false
        var blockMatches = false
        var blockStart = -1
        var pinned = false

        func lineKeyValue(_ line: String) -> (key: String, value: String)? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
            let k = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let v = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (k, v)
        }

        func finishBlock(endingBefore end: Int) {
            guard inTargetBlock, blockMatches, !pinned else { return }
            for lineIndex in blockStart..<end {
                if let kv = lineKeyValue(lines[lineIndex]), kv.key == key {
                    lines[lineIndex] = "\(key) = \"\(value)\""
                    pinned = true
                    return
                }
            }
            for lineIndex in blockStart..<end {
                if let kv = lineKeyValue(lines[lineIndex]), kv.key == matchKey, kv.value == matchValue {
                    lines.insert("\(key) = \"\(value)\"", at: lineIndex + 1)
                    pinned = true
                    return
                }
            }
        }

        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                finishBlock(endingBefore: index)
                if pinned { break }
                inTargetBlock = trimmed == "[[\(section)]]"
                blockMatches = false
                blockStart = index + 1
            } else if inTargetBlock, let kv = lineKeyValue(lines[index]),
                      kv.key == matchKey, kv.value == matchValue {
                blockMatches = true
            }
            index += 1
        }
        finishBlock(endingBefore: lines.count)

        let updated = lines.joined(separator: "\n")
        if pinned && updated != contents {
            try? updated.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }
}
