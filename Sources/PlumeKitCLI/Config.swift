import Foundation

// Reads the `[build]` section of a project's plumekit.toml so `plumekit build` knows
// which target(s) to build without a `--target` flag. (The capability/driver sections
// are read separately by the PlumeKitCodegen build plugin at compile time.)
struct BuildConfig {
    var defaultTarget: String?   // [build] default = "cloudflare"
    var targets: [String]        // [build] targets = ["cloudflare", "aws"]
    var out: String = "dist"     // [build] out = "dist" — bundle output directory
    var deployMigrate = true     // [deploy] migrate = true  — run migrations on deploy
    var deploySeed = false       // [deploy] seed = false    — run seeders on deploy

    static func read(projectPath: String) -> BuildConfig {
        var config = BuildConfig(defaultTarget: nil, targets: [])
        guard let toml = try? String(contentsOfFile: projectPath + "/plumekit.toml", encoding: .utf8)
        else { return config }

        var section = ""
        for raw in toml.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()); continue
            }
            guard section == "build" || section == "deploy", let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var valuePart = String(line[line.index(after: eq)...])
            if let hash = valuePart.firstIndex(of: "#") { valuePart = String(valuePart[..<hash]) }
            let value = valuePart.trimmingCharacters(in: .whitespaces)

            if section == "deploy" {
                switch key {
                case "migrate": config.deployMigrate = (value == "true")
                case "seed": config.deploySeed = (value == "true")
                default: break
                }
                continue
            }

            switch key {
            case "default":
                config.defaultTarget = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "targets":
                config.targets = value
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
                    .filter { !$0.isEmpty }
            case "out":
                let dir = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !dir.isEmpty { config.out = dir }
            default: break
            }
        }
        return config
    }

    /// Targets a bare `plumekit build` (no `--target`) should build: the configured
    /// default if set, otherwise every declared target.
    var resolvedTargets: [String] {
        if let defaultTarget { return [defaultTarget] }
        return targets
    }
}
