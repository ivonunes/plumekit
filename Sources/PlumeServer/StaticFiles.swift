#if canImport(Darwin)
@preconcurrency import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
#endif
import Foundation
import PlumeCore
import NIOCore

// Static file serving for the native server. A request whose path maps to a real file
// under the project's `Public/` directory is answered directly; everything else falls
// through to the app's routes. On the edge (Cloudflare assets, S3/CloudFront) the platform
// serves these same URL paths, so an app references `/logo.png` the same way everywhere —
// only *who* serves it changes per target.
//
// Files are sent as a `FileRegion` (kernel sendfile on the event loop), never buffered
// into memory, and carry validators (ETag / Last-Modified) so repeat visits are 304s.
enum StaticFiles {
    /// Resolve the public root once at startup: absolute, `.`-free, symlinks resolved.
    /// Per-request containment checks compare against this fixed prefix, so a changing
    /// working directory (or a symlinked root) can't confuse them. Nil when the
    /// directory doesn't exist.
    static func resolveRoot(_ directory: String) -> String? {
        let absolute = directory.hasPrefix("/")
            ? directory
            : FileManager.default.currentDirectoryPath + "/" + directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: absolute, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Everything needed to answer a static GET/HEAD without reading the file:
    /// the resolved on-disk path, size, headers and validators.
    struct FileInfo {
        let path: String
        let size: Int
        let contentType: String
        let cacheControl: String
        let etag: String
        let lastModified: String
    }

    /// Map a request path to a regular file inside `root` (already resolved by
    /// `resolveRoot`), or nil to let the app's routes handle it. Only stats the
    /// file — the caller streams it.
    static func lookup(requestPath: String, root: String) -> FileInfo? {
        let decoded = requestPath.removingPercentEncoding ?? requestPath
        let relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        if relative.isEmpty { return nil }

        // Fast path for the overwhelmingly common case — a dynamic route like
        // /posts/42 that names no file: one stat of the naive join and out. The
        // URL standardisation + symlink resolution below costs several syscalls
        // and Foundation allocations, so it runs only when something exists.
        var probe = stat()
        guard stat(root + "/" + relative, &probe) == 0 else { return nil }

        // Resolve `..`/`.` AND symlinks, then require the result to stay inside the
        // public root: neither a crafted path nor a symlink placed under Public/ can
        // escape the directory.
        let target = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(relative)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard target.path == root || target.path.hasPrefix(root + "/") else { return nil }

        var status = stat()
        guard stat(target.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(status.st_size)
        #if canImport(Darwin)
        let mtime = Int(status.st_mtimespec.tv_sec)
        #else
        let mtime = Int(status.st_mtim.tv_sec)
        #endif
        return FileInfo(
            path: target.path,
            size: size,
            contentType: contentType(forExtension: target.pathExtension),
            cacheControl: cacheControl(forFile: target.lastPathComponent),
            // Weak validator from size + mtime — no file read, and it changes
            // whenever the content plausibly did.
            etag: "W/\"\(size)-\(mtime)\"",
            lastModified: httpDate(mtime))
    }

    /// Open for reading. A non-async wrapper because the underlying open(2) is
    /// nominally blocking (it's a fast metadata syscall) and NIO marks the
    /// initializer `noasync`.
    static func open(_ path: String) throws -> NIOFileHandle {
        try NIOFileHandle(_deprecatedPath: path, mode: .read)
    }

    static func close(_ handle: NIOFileHandle) {
        try? handle.close()
    }

    /// `Sat, 01 Feb 2026 12:00:00 GMT` — via gmtime/strftime, no Foundation
    /// formatter (they aren't Sendable and this runs on many tasks).
    private static func httpDate(_ epochSeconds: Int) -> String {
        var seconds = time_t(epochSeconds)
        var components = tm()
        gmtime_r(&seconds, &components)
        var buffer = [CChar](repeating: 0, count: 40)
        let length = strftime(&buffer, buffer.count, "%a, %d %b %Y %H:%M:%S GMT", &components)
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Content-hashed bundle files (`app.<hash>.css` / `app.<hash>.js`) never
    /// change under the same name, so they cache forever; everything else
    /// revalidates hourly.
    private static func cacheControl(forFile name: String) -> String {
        let parts = name.split(separator: ".")
        if parts.count == 3, parts[0] == "app",
           parts[1].count == 16, parts[1].allSatisfy({ $0.isHexDigit }) {
            return "public, max-age=31536000, immutable"
        }
        return "public, max-age=3600"
    }

    private static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "webmanifest": return "application/manifest+json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
