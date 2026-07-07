import Foundation
import PlumeCore

extension PlumeServer {
    /// An interactive REPL that dispatches typed requests through `app` using the
    /// same async pipeline and native `context` as `serve` — so you can exercise
    /// async handlers and the native KV without an HTTP client.
    ///
    /// Type `METHOD /path` (e.g. `GET /count`); blank method defaults to GET.
    /// `quit` / `exit` / EOF ends the session.
    public static func console(_ app: Application, context: Context) async {
        NativeDrivers.installNativeClock()
        print("plumekit console — type `GET /count` etc., or `quit`.")
        while true {
            FileHandle.standardOutput.write(Data("> ".utf8))
            guard let line = readLine(strippingNewline: true) else { print(""); break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed == "quit" || trimmed == "exit" { break }

            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let methodName = String(parts[0]).uppercased()
            let target = parts.count >= 2 ? String(parts[1]) : "/"
            guard let method = HTTPMethod(name: methodName) else {
                print("unknown method '\(methodName)'")
                continue
            }

            let (path, query) = splitTarget(target)
            let request = Request(method: method, path: path, query: query, context: context)
            let response = await app.handle(request)
            print("\(response.status) \(response.reasonPhrase)")
            if !response.body.isEmpty {
                print(decodeUTF8(response.body))
            }
        }
    }

    private static func splitTarget(_ target: String) -> (String, String) {
        if let q = target.firstIndex(of: "?") {
            return (String(target[target.startIndex..<q]), String(target[target.index(after: q)...]))
        }
        return (target, "")
    }
}
