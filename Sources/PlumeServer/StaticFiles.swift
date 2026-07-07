import Foundation
import PlumeCore

// Static file serving for the native server. A request whose path maps to a real file
// under the project's `Public/` directory is answered directly; everything else falls
// through to the app's routes. On the edge (Cloudflare assets, S3/CloudFront) the platform
// serves these same URL paths, so an app references `/logo.png` the same way everywhere —
// only *who* serves it changes per target.
enum StaticFiles {
    /// A response for `path` if it resolves to a regular file inside `directory`
    /// (absolute), else `nil` to let the app handle the request.
    static func response(for path: String, in directory: String) -> Response? {
        let decoded = (path.removingPercentEncoding ?? path)
        let relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        if relative.isEmpty { return nil }

        // Resolve `..`/`.` AND symlinks, then require the result to stay inside the
        // public root: neither a crafted path nor a symlink placed under Public/ can
        // escape the directory.
        let root = URL(fileURLWithPath: directory, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(relative)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let data = FileManager.default.contents(atPath: target.path) else { return nil }

        var headers = Headers()
        headers.add("content-type", contentType(forExtension: target.pathExtension))
        headers.add("cache-control", "public, max-age=3600")
        return Response(status: 200, headers: headers, body: [UInt8](data))
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
