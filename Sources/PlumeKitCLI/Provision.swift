import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Self-provisioning of Cloudflare build tools — the Embedded-Swift Wasm SDK (via
// `swift sdk install`) and binaryen's wasm-opt (a checksummed release download into
// the plumekit cache) — so a machine needs only a Swift toolchain.

/// The plumekit cache directory (same layout the ./plumekit wrapper uses).
func plumeKitCacheDir() -> String {
    let env = ProcessInfo.processInfo.environment
    if let override = env["PLUMEKIT_CACHE"], !override.isEmpty { return override }
    if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty { return xdg + "/plumekit" }
    return NSHomeDirectory() + "/.cache/plumekit"
}

// MARK: - Embedded Wasm SDK

/// swift.org Wasm SDK bundles by toolchain version. An SDK only works with the
/// exact same toolchain, so unknown versions keep the manual-install error path.
private let wasmSDKBundles: [String: (url: String, checksum: String)] = [
    "6.3.2": ("https://download.swift.org/swift-6.3.2-release/wasm-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_wasm.artifactbundle.tar.gz",
              "a61f0584c93283589f8b2f42db05c1f9a182b506c2957271402992655591dd7c"),
]

/// Install the Embedded Wasm SDK matching the host toolchain when its bundle is
/// known, returning the installed SDK id.
func installEmbeddedWasmSDK() -> String? {
    guard let version = hostSwiftVersion(), let bundle = wasmSDKBundles[version] else { return nil }
    print("→ Installing the Swift SDK for WebAssembly (\(version)) — one-time, ~70 MB")
    guard runInherit("swift", ["sdk", "install", bundle.url, "--checksum", bundle.checksum]) == 0 else { return nil }
    return embeddedWasmSDK()
}

/// "6.3.2" out of `swift --version`.
private func hostSwiftVersion() -> String? {
    let out = capture("swift", ["--version"]).output
    guard let marker = out.range(of: "Swift version ") else { return nil }
    let version = out[marker.upperBound...].prefix(while: { $0.isNumber || $0 == "." })
    return version.isEmpty ? nil : String(version)
}

// MARK: - wasm-opt (binaryen)

private let binaryenVersion = "version_131"
private let binaryenChecksums: [String: String] = [
    "aarch64-linux": "ba991f677edd9a21d2bc96c0144bc8ac5b112d4d98a3eb266e075e22e557df2a",
    "arm64-macos": "e441b48dc22163d209b4f05e44dc7210909b01237642b6c9ae48fd710a3ef83e",
    "x86_64-linux": "b5bf1f0eaf17c63ee588ff7a5954dc8f6ce2c26989051c66f24dfe9ece3e46db",
    "x86_64-macos": "d209fadd8a894bdaf3bd3612a23c32a0af184d2f4a979b8c789e6e4f6a4de883",
]

/// A wasm-opt that is already available without downloading: PATH, or the cache.
func cachedWasmOpt() -> String? {
    if toolExists("wasm-opt") { return "wasm-opt" }
    let cached = plumeKitCacheDir() + "/binaryen-\(binaryenVersion)/bin/wasm-opt"
    return FileManager.default.isExecutableFile(atPath: cached) ? cached : nil
}

/// A runnable wasm-opt, downloading binaryen's release build on first use.
/// nil means the caller falls back to emitting unoptimized wasm.
func provisionedWasmOpt() -> String? {
    if let existing = cachedWasmOpt() { return existing }

    let os: String
    #if os(macOS)
    os = "macos"
    #elseif os(Linux)
    os = "linux"
    #else
    return nil
    #endif
    let arch: String
    #if arch(arm64)
    arch = os == "macos" ? "arm64" : "aarch64"
    #elseif arch(x86_64)
    arch = "x86_64"
    #else
    return nil
    #endif

    let platform = "\(arch)-\(os)"
    guard let checksum = binaryenChecksums[platform] else { return nil }
    let name = "binaryen-\(binaryenVersion)-\(platform).tar.gz"
    let url = "https://github.com/WebAssembly/binaryen/releases/download/\(binaryenVersion)/\(name)"
    print("→ Fetching wasm-opt (binaryen \(binaryenVersion), \(platform)) — one-time")

    let tarball = NSTemporaryDirectory() + "/" + name
    defer { try? FileManager.default.removeItem(atPath: tarball) }
    guard downloadFile(url: url, to: tarball) else {
        errorLine("wasm-opt download failed (\(url))")
        return nil
    }
    guard sha256File(tarball) == checksum else {
        errorLine("wasm-opt download failed checksum verification — not using it")
        return nil
    }

    // The tarball unpacks as binaryen-version_NNN/bin/wasm-opt (+ its lib/).
    let cacheRoot = plumeKitCacheDir()
    try? FileManager.default.createDirectory(atPath: cacheRoot, withIntermediateDirectories: true)
    let binary = cacheRoot + "/binaryen-\(binaryenVersion)/bin/wasm-opt"
    guard runInherit("tar", ["-xzf", tarball, "-C", cacheRoot]) == 0,
          FileManager.default.isExecutableFile(atPath: binary) else {
        errorLine("could not unpack \(name)")
        return nil
    }
    return binary
}

// MARK: - Helpers

private final class DownloadBox: @unchecked Sendable { var ok = false }

private func downloadFile(url: String, to path: String) -> Bool {
    guard let remote = URL(string: url) else { return false }
    let done = DispatchSemaphore(value: 0)
    let box = DownloadBox()
    URLSession.shared.downloadTask(with: remote) { location, response, _ in
        defer { done.signal() }
        guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        try? FileManager.default.removeItem(atPath: path)
        box.ok = (try? FileManager.default.moveItem(atPath: location.path, toPath: path)) != nil
    }.resume()
    done.wait()
    return box.ok
}

private func sha256File(_ path: String) -> String? {
    for tool in [("sha256sum", [path]), ("shasum", ["-a", "256", path])] {
        let run = capture(tool.0, tool.1)
        if run.status == 0, let sum = run.output.split(separator: " ").first { return String(sum) }
    }
    return nil
}
