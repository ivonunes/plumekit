import Foundation
import Plume

@main
struct PlumeCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        do {
            switch command {
            case "check":
                try runCheck(options: Array(arguments.dropFirst()))
            case "format":
                try runFormat(options: Array(arguments.dropFirst()))
            case "language-server":
                PlumeLanguageServer().run()
            case "version", "--version", "-v":
                print(PlumeVersion.current)
            default:
                print(help)
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static var help: String {
        """
        Plume

        Commands:
          check [path ...]             Check Plume templates
          format [--check] [path ...]  Format Plume templates
          format --stdin               Format standard input
          language-server              Start the Plume language server
          version                      Print the Plume CLI version
        """
    }

    private static func runCheck(options: [String]) throws {
        let files = try plumeFiles(paths: options.filter { !$0.hasPrefix("-") })
        guard !files.isEmpty else {
            print("No .plume templates found.")
            return
        }

        let componentSources = Dictionary(uniqueKeysWithValues: try files.map { file in
            (relativePath(file), try String(contentsOf: file, encoding: .utf8))
        })
        let environment = PlumeLanguageSupport.environment(componentSources: componentSources)
        var failed = false
        for file in files {
            let name = relativePath(file)
            let source = try componentSources[name] ?? String(contentsOf: file, encoding: .utf8)
            let diagnostics = PlumeLanguageSupport.diagnostics(
                for: source,
                sourceName: name,
                environment: environment
            )
            for diagnostic in diagnostics {
                failed = true
                print("\(diagnostic.sourceName ?? name):\(diagnostic.line):\(diagnostic.column): \(diagnostic.message)")
            }
        }
        if failed { exit(1) }
        print("Plume check passed (\(files.count) templates).")
    }

    private static func runFormat(options: [String]) throws {
        if options.contains("--stdin") {
            print(PlumeFormatter.format(readStandardInput()), terminator: "")
            return
        }

        let checkOnly = options.contains("--check")
        let files = try plumeFiles(paths: options.filter { !$0.hasPrefix("-") })
        guard !files.isEmpty else {
            print("No .plume templates found.")
            return
        }

        var changed: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let formatted = PlumeFormatter.format(source)
            guard formatted != source else { continue }
            changed.append(relativePath(file))
            if !checkOnly {
                try formatted.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        if changed.isEmpty {
            print("Plume templates are already formatted.")
            return
        }
        for path in changed {
            print("\(checkOnly ? "Would format" : "Formatted") \(path)")
        }
        if checkOnly { exit(1) }
    }

    private static func plumeFiles(paths: [String]) throws -> [URL] {
        let roots = paths.isEmpty ? [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] : paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        var files: [URL] = []
        for root in roots {
            let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isRegularFile == true, root.pathExtension == "plume" {
                files.append(root)
                continue
            }
            guard values?.isDirectory == true,
                  let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for case let file as URL in enumerator {
                if shouldSkipDirectory(file) {
                    enumerator.skipDescendants()
                    continue
                }
                if file.pathExtension == "plume",
                   (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    files.append(file)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func shouldSkipDirectory(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
        return [".build", ".cache", ".git", "dist", "node_modules"].contains(url.lastPathComponent)
    }

    private static func relativePath(_ url: URL) -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root) else { return path }
        return path.dropFirst(root.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func readStandardInput() -> String {
        String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
