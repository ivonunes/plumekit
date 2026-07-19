import Foundation

// API-direct Cloudflare deploy: the whole `wrangler deploy` surface plumekit uses —
// assets, module upload, bindings, durable-object migrations, cron schedules, queue
// consumers and custom domains — over the REST API, driven by the generated
// bundle wrangler.toml. This is the only deploy path; auth: CloudflareAuth.swift.

/// Deploy the built bundle in `bundleDir`. Returns a process exit status.
func deployCloudflareViaAPI(projectRoot: String, bundleDir: String, api: CloudflareAPI,
                            config initialConfig: WranglerConfig, env: String? = nil) -> Int32 {
    guard let script = initialConfig.name, !script.isEmpty else {
        errorLine("wrangler.toml has no `name` — the worker needs one to deploy")
        return 1
    }

    // Resolve-or-create the declared resources first; bindings need real ids.
    guard let config = provisionCloudflareResources(
        config: initialConfig, api: api,
        projectRoot: projectRoot, bundleToml: bundleDir + "/wrangler.toml", env: env) else {
        return 1
    }

    // 1. Assets: manifest → upload session → upload the buckets Cloudflare asks for.
    var assetsJWT: String?
    if let directory = config.assets?.directory {
        let assetsDir = bundleDir + "/" + directory.replacingOccurrences(of: "./", with: "")
        let assets = collectAssets(directory: assetsDir)
        if !assets.isEmpty {
            var manifest: [String: Any] = [:]
            for asset in assets { manifest["/" + asset.path] = ["hash": asset.hash, "size": asset.size] }
            guard let session = api.startAssetsUploadSession(script: script, manifest: manifest) else { return 1 }
            // No buckets → every asset is already stored; the session token completes.
            var completion = session.jwt
            let byHash = Dictionary(assets.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
            for bucket in session.buckets where !bucket.isEmpty {
                var form = MultipartForm()
                for hash in bucket {
                    guard let asset = byHash[hash],
                          let bytes = FileManager.default.contents(atPath: assetsDir + "/" + asset.path) else {
                        errorLine("asset for hash \(hash) disappeared during upload")
                        return 1
                    }
                    form.addField(name: hash, value: bytes.base64EncodedString(), contentType: asset.contentType)
                }
                guard let jwt = api.uploadAssetBucket(form: form, sessionJWT: session.jwt) else { return 1 }
                completion = jwt
            }
            assetsJWT = completion
            let uploaded = session.buckets.reduce(0) { $0 + $1.count }
            print("  assets        \(assets.count) files (\(uploaded) uploaded, rest unchanged)")
        }
    }

    // 2. Durable-object migrations: only the steps after the deployed script's tag.
    // A tag that is missing OR not in our list (scripts migrated under wrangler
    // carry their own tag history, e.g. a v2 we never declared) falls back to the
    // namespaces API: drop steps whose classes are already live.
    let currentTag = api.scriptMigrationTag(script: script)
    var pendingMigrations = config.migrations
    if let currentTag, let index = pendingMigrations.firstIndex(where: { $0.tag == currentTag }) {
        pendingMigrations.removeFirst(index + 1)
    } else {
        let liveClasses = api.durableObjectClasses(script: script)
        if !liveClasses.isEmpty {
            pendingMigrations = pendingMigrations.compactMap { step in
                var step = step
                step.newClasses.removeAll { liveClasses.contains($0) }
                step.newSqliteClasses.removeAll { liveClasses.contains($0) }
                return (step.newClasses.isEmpty && step.newSqliteClasses.isEmpty) ? nil : step
            }
        }
    }

    // 3. The script upload: metadata JSON + the bundle's module files.
    var metadata: [String: Any] = [
        "main_module": config.main ?? "worker.mjs",
        // Secrets are set out-of-band (`plumekit secrets` / wrangler) and must
        // survive deploys — without keep_bindings a module upload drops them.
        "keep_bindings": ["secret_text", "secret_key"],
    ]
    if let date = config.compatibilityDate { metadata["compatibility_date"] = date }
    if !config.compatibilityFlags.isEmpty { metadata["compatibility_flags"] = config.compatibilityFlags }
    if let assetsJWT {
        var assetsMeta: [String: Any] = ["jwt": assetsJWT]
        var assetsConfig: [String: Any] = [:]
        if let html = config.assets?.htmlHandling { assetsConfig["html_handling"] = html }
        if let notFound = config.assets?.notFoundHandling { assetsConfig["not_found_handling"] = notFound }
        if !assetsConfig.isEmpty { assetsMeta["config"] = assetsConfig }
        metadata["assets"] = assetsMeta
    }
    if !pendingMigrations.isEmpty {
        var migrations: [String: Any] = [
            "new_tag": pendingMigrations[pendingMigrations.count - 1].tag,
            "steps": pendingMigrations.map { step -> [String: Any] in
                var out: [String: Any] = [:]
                if !step.newClasses.isEmpty { out["new_classes"] = step.newClasses }
                if !step.newSqliteClasses.isEmpty { out["new_sqlite_classes"] = step.newSqliteClasses }
                return out
            },
        ]
        if let currentTag { migrations["old_tag"] = currentTag }
        metadata["migrations"] = migrations
    }
    metadata["bindings"] = bindingsMetadata(config: config)

    func scriptForm(_ metadata: [String: Any]) -> MultipartForm? {
        guard let metadataJSON = try? JSONSerialization.data(withJSONObject: metadata) else { return nil }
        var form = MultipartForm()
        form.addField(name: "metadata", value: String(decoding: metadataJSON, as: UTF8.self),
                      contentType: "application/json")
        for module in bundleModules(bundleDir: bundleDir) {
            guard let bytes = FileManager.default.contents(atPath: bundleDir + "/" + module.file) else { continue }
            form.addFile(name: module.file, filename: module.file, mimeType: module.mime, bytes: bytes)
        }
        return form
    }

    print(Style.cyan("→") + " Deploying \"\(script)\" (Cloudflare API)")
    guard let form = scriptForm(metadata) else { return 1 }
    var upload = api.uploadScript(script: script, form: form, quietErrors: true)
    if !upload.ok, metadata["migrations"] != nil, (upload.error ?? "").contains("already depended on") {
        // The durable-object classes are live even though no migration tag could be
        // read back — the migration step is redundant, so send without it.
        print("  (durable-object classes already live — retrying without the migration step)")
        var trimmed = metadata
        trimmed.removeValue(forKey: "migrations")
        guard let retryForm = scriptForm(trimmed) else { return 1 }
        upload = api.uploadScript(script: script, form: retryForm)
    } else if !upload.ok {
        errorLine("Cloudflare API error (PUT /accounts/\(api.accountId)/workers/scripts/\(script)): "
                  + (upload.error ?? "unknown error"))
    }
    guard upload.ok else { return 1 }

    // 4. The pieces `wrangler deploy` configures alongside the script.
    if !config.crons.isEmpty {
        guard api.putSchedules(script: script, crons: config.crons) else { return 1 }
        print("  schedules     \(config.crons.joined(separator: ", "))")
    }
    for consumer in config.queueConsumers {
        guard let queueId = api.queueId(name: consumer.queue) else {
            errorLine("queue \"\(consumer.queue)\" not found on the account — create it first")
            return 1
        }
        var settings: [String: Any] = [:]
        if let size = consumer.maxBatchSize { settings["batch_size"] = size }
        if let timeout = consumer.maxBatchTimeout { settings["max_wait_time_ms"] = timeout * 1000 }
        if let retries = consumer.maxRetries { settings["max_retries"] = retries }
        guard api.ensureQueueConsumer(queueId: queueId, script: script, settings: settings) else { return 1 }
        print("  queue         \(consumer.queue) → \(script)")
    }
    for route in config.routes {
        if route.customDomain {
            // The domains API wants the zone; derive it from the hostname when the
            // config doesn't carry one (needs the token's Zone read permission).
            guard let zone = route.zoneName ?? api.findZone(forHost: route.pattern) else {
                errorLine("no zone on this account matches \"\(route.pattern)\" — is the domain "
                          + "on Cloudflare, and does the token have Zone read permission?")
                return 1
            }
            guard api.putCustomDomain(hostname: route.pattern, zoneName: zone, script: script) else {
                return 1
            }
            print("  domain        https://\(route.pattern)")
        } else {
            errorLine("route \"\(route.pattern)\" is not a custom domain — plain zone routes aren't "
                      + "managed by the API deploy yet; add it once in the dashboard or with wrangler.")
        }
    }
    if config.workersDev == true {
        _ = api.callJSON("POST", "/accounts/\(api.accountId)/workers/scripts/\(script)/subdomain",
                         json: ["enabled": true], quietErrors: true)
    }
    print(Style.green("✓") + " Deployed \"\(script)\"")
    return 0
}

// MARK: - Assets

private struct DeployAsset { let path: String; let hash: String; let size: Int; let contentType: String }

/// Every file under the assets directory, with Cloudflare's asset hash:
/// BLAKE3(base64(contents) + extension), first 32 hex characters.
private func collectAssets(directory: String) -> [DeployAsset] {
    guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: directory) else { return [] }
    var assets: [DeployAsset] = []
    for path in subpaths.sorted() {
        var isDirectory: ObjCBool = false
        let full = directory + "/" + path
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let bytes = FileManager.default.contents(atPath: full) else { continue }
        let ext = (path as NSString).pathExtension
        let hashInput = Data((bytes.base64EncodedString() + ext).utf8)
        let hash = String(BLAKE3.hex(hashInput).prefix(32))
        assets.append(DeployAsset(path: path, hash: hash, size: bytes.count, contentType: mimeType(extension: ext)))
    }
    return assets
}

private func mimeType(extension ext: String) -> String {
    switch ext.lowercased() {
    case "html", "htm": return "text/html"
    case "css": return "text/css"
    case "js", "mjs": return "text/javascript"
    case "json", "map": return "application/json"
    case "svg": return "image/svg+xml"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "avif": return "image/avif"
    case "ico": return "image/x-icon"
    case "txt": return "text/plain"
    case "xml": return "application/xml"
    case "pdf": return "application/pdf"
    case "wasm": return "application/wasm"
    case "woff": return "font/woff"
    case "woff2": return "font/woff2"
    case "ttf": return "font/ttf"
    case "webmanifest", "manifest": return "application/manifest+json"
    default: return "application/octet-stream"
    }
}

// MARK: - Modules & bindings

/// The bundle's module files: the worker entry and everything it imports
/// (worker.mjs + app.wasm today; any extra .mjs/.wasm files ride along).
private func bundleModules(bundleDir: String) -> [(file: String, mime: String)] {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: bundleDir)) ?? []
    return entries.sorted().compactMap { file in
        if file.hasSuffix(".mjs") || file.hasSuffix(".js") { return (file, "application/javascript+module") }
        if file.hasSuffix(".wasm") { return (file, "application/wasm") }
        return nil
    }
}

private func bindingsMetadata(config: WranglerConfig) -> [[String: Any]] {
    var bindings: [[String: Any]] = []
    if let assetsBinding = config.assets?.binding {
        bindings.append(["type": "assets", "name": assetsBinding])
    }
    for kv in config.kvNamespaces {
        bindings.append(["type": "kv_namespace", "name": kv.binding, "namespace_id": kv.id])
    }
    for d1 in config.d1Databases {
        bindings.append(["type": "d1", "name": d1.binding, "id": d1.databaseId])
    }
    for r2 in config.r2Buckets {
        bindings.append(["type": "r2_bucket", "name": r2.binding, "bucket_name": r2.bucketName])
    }
    for producer in config.queueProducers {
        bindings.append(["type": "queue", "name": producer.binding, "queue_name": producer.queue])
    }
    for durable in config.durableObjects {
        bindings.append(["type": "durable_object_namespace", "name": durable.name, "class_name": durable.className])
    }
    for (name, value) in config.vars.sorted(by: { $0.key < $1.key }) {
        bindings.append(["type": "plain_text", "name": name, "text": value])
    }
    return bindings
}
