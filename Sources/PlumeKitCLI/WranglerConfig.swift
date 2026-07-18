import Foundation

// The subset of wrangler.toml the CLI needs for API-direct deploys. The file stays
// user-owned and wrangler-compatible (it is the ecosystem format for Worker config,
// and the escape hatch to plain wrangler must keep working); this just reads it.
struct WranglerConfig {
    var name: String?
    var main: String?
    var accountId: String?
    var compatibilityDate: String?
    var compatibilityFlags: [String] = []
    var workersDev: Bool?

    struct Assets { var directory: String?; var binding: String?
                    var htmlHandling: String?; var notFoundHandling: String? }
    var assets: Assets?

    struct KVNamespace { var binding = ""; var id = "" }
    var kvNamespaces: [KVNamespace] = []

    struct D1Database { var binding = ""; var databaseName = ""; var databaseId = "" }
    var d1Databases: [D1Database] = []

    struct R2Bucket { var binding = ""; var bucketName = "" }
    var r2Buckets: [R2Bucket] = []

    struct QueueProducer { var binding = ""; var queue = "" }
    var queueProducers: [QueueProducer] = []

    struct QueueConsumer { var queue = ""; var maxBatchSize: Int?; var maxBatchTimeout: Int?
                           var maxRetries: Int? }
    var queueConsumers: [QueueConsumer] = []

    struct DurableObjectBinding { var name = ""; var className = "" }
    var durableObjects: [DurableObjectBinding] = []

    struct DOMigration { var tag = ""; var newClasses: [String] = []; var newSqliteClasses: [String] = [] }
    var migrations: [DOMigration] = []

    var crons: [String] = []
    var vars: [String: String] = [:]

    struct Route { var pattern = ""; var zoneName: String?; var customDomain = false }
    var routes: [Route] = []

    /// Parse the file. Line-oriented TOML subset: `[section]`, `[[array-of-tables]]`,
    /// quoted strings, booleans, integers, and single-line string arrays — the shapes
    /// wrangler.toml actually uses.
    static func load(_ path: String) -> WranglerConfig? {
        guard let toml = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var config = WranglerConfig()
        var section = ""

        for raw in toml.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[[") && line.hasSuffix("]]") {
                section = String(line.dropFirst(2).dropLast(2))
                switch section {
                case "kv_namespaces": config.kvNamespaces.append(KVNamespace())
                case "d1_databases": config.d1Databases.append(D1Database())
                case "r2_buckets": config.r2Buckets.append(R2Bucket())
                case "queues.producers": config.queueProducers.append(QueueProducer())
                case "queues.consumers": config.queueConsumers.append(QueueConsumer())
                case "durable_objects.bindings": config.durableObjects.append(DurableObjectBinding())
                case "migrations": config.migrations.append(DOMigration())
                case "routes": config.routes.append(Route())
                default: break
                }
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                if section == "assets" && config.assets == nil { config.assets = Assets() }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = tomlValue(String(line[line.index(after: eq)...]))

            switch section {
            case "":
                switch key {
                case "name": config.name = value.string
                case "main": config.main = value.string
                case "account_id": config.accountId = value.string
                case "compatibility_date": config.compatibilityDate = value.string
                case "compatibility_flags": config.compatibilityFlags = value.strings
                case "workers_dev": config.workersDev = value.bool
                default: break
                }
            case "assets":
                switch key {
                case "directory": config.assets?.directory = value.string
                case "binding": config.assets?.binding = value.string
                case "html_handling": config.assets?.htmlHandling = value.string
                case "not_found_handling": config.assets?.notFoundHandling = value.string
                default: break
                }
            case "triggers":
                if key == "crons" { config.crons = value.strings }
            case "vars":
                if let v = value.string { config.vars[key] = v }
            case "kv_namespaces":
                switch key {
                case "binding": config.kvNamespaces.mutateLast { $0.binding = value.string ?? "" }
                case "id": config.kvNamespaces.mutateLast { $0.id = value.string ?? "" }
                default: break
                }
            case "d1_databases":
                switch key {
                case "binding": config.d1Databases.mutateLast { $0.binding = value.string ?? "" }
                case "database_name": config.d1Databases.mutateLast { $0.databaseName = value.string ?? "" }
                case "database_id": config.d1Databases.mutateLast { $0.databaseId = value.string ?? "" }
                default: break
                }
            case "r2_buckets":
                switch key {
                case "binding": config.r2Buckets.mutateLast { $0.binding = value.string ?? "" }
                case "bucket_name": config.r2Buckets.mutateLast { $0.bucketName = value.string ?? "" }
                default: break
                }
            case "queues.producers":
                switch key {
                case "binding": config.queueProducers.mutateLast { $0.binding = value.string ?? "" }
                case "queue": config.queueProducers.mutateLast { $0.queue = value.string ?? "" }
                default: break
                }
            case "queues.consumers":
                switch key {
                case "queue": config.queueConsumers.mutateLast { $0.queue = value.string ?? "" }
                case "max_batch_size": config.queueConsumers.mutateLast { $0.maxBatchSize = value.int }
                case "max_batch_timeout": config.queueConsumers.mutateLast { $0.maxBatchTimeout = value.int }
                case "max_retries": config.queueConsumers.mutateLast { $0.maxRetries = value.int }
                default: break
                }
            case "durable_objects.bindings":
                switch key {
                case "name": config.durableObjects.mutateLast { $0.name = value.string ?? "" }
                case "class_name": config.durableObjects.mutateLast { $0.className = value.string ?? "" }
                default: break
                }
            case "migrations":
                switch key {
                case "tag": config.migrations.mutateLast { $0.tag = value.string ?? "" }
                case "new_classes": config.migrations.mutateLast { $0.newClasses = value.strings }
                case "new_sqlite_classes": config.migrations.mutateLast { $0.newSqliteClasses = value.strings }
                default: break
                }
            case "routes":
                switch key {
                case "pattern": config.routes.mutateLast { $0.pattern = value.string ?? "" }
                case "zone_name": config.routes.mutateLast { $0.zoneName = value.string }
                case "custom_domain": config.routes.mutateLast { $0.customDomain = value.bool ?? false }
                default: break
                }
            default: break
            }
        }
        return config
    }
}

/// A parsed TOML value: string, bool, int, or array of strings.
private struct TOMLValue {
    var string: String?
    var strings: [String] = []
    var bool: Bool?
    var int: Int?
}

private func tomlValue(_ rawInput: String) -> TOMLValue {
    // Strip a trailing comment — only a '#' outside quotes starts one.
    var raw = rawInput
    var inQuote = false
    for index in rawInput.indices {
        let character = rawInput[index]
        if character == "\"" { inQuote.toggle() }
        else if character == "#" && !inQuote { raw = String(rawInput[..<index]); break }
    }
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    var value = TOMLValue()
    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        value.strings = trimmed.dropFirst().dropLast()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty }
    } else if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
        value.string = String(trimmed.dropFirst().dropLast())
    } else if trimmed == "true" || trimmed == "false" {
        value.bool = trimmed == "true"
    } else if let number = Int(trimmed) {
        value.int = number
    } else if !trimmed.isEmpty {
        value.string = trimmed
    }
    return value
}

private extension Array {
    mutating func mutateLast(_ change: (inout Element) -> Void) {
        guard !isEmpty else { return }
        change(&self[count - 1])
    }
}
