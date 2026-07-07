import Foundation
import PlumeCore

// DynamoDB adapters — the AWS backing for the KV and Cache capabilities, plus the
// state/connection store the API Gateway channel needs. Uses the DynamoDB JSON
// protocol (`DynamoDB_20120810.*`) over the shared SigV4 sender, so it needs no AWS
// SDK. Endpoint is overridable (point it at LocalStack for local testing).
//
// Table shape (single-attribute key, created by the app / harness):
//   • KV / Cache: partition key `pk` (S), value `val` (B); Cache adds `ttl` (N).
//   • Channels:   state items keyed by `pk = "state#<channel>#<key>"`; connection
//                 items keyed by `pk = "conn#<channel>#<connID>"`.

/// A thin DynamoDB JSON client. `region`/`endpoint` select the target; `endpoint`
/// defaults to the real AWS host and is overridden for LocalStack.
public struct DynamoDB: Sendable {
    let endpoint: String
    let signer: SigV4

    public init(region: String, accessKey: String, secretKey: String, endpoint: String? = nil) {
        self.endpoint = (endpoint ?? "https://dynamodb.\(region).amazonaws.com") .trimmingSlash()
        self.signer = SigV4(region: region, service: "dynamodb", accessKey: accessKey, secretKey: secretKey)
    }

    /// POST one DynamoDB JSON operation; returns the decoded response object.
    func call(_ target: String, _ payload: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, status) = try await AWSHTTP.send(
            signer: signer, method: "POST", urlString: endpoint + "/",
            contentType: "application/x-amz-json-1.0",
            amzTarget: "DynamoDB_20120810." + target, body: body)
        guard (200..<300).contains(status) else {
            throw AWSError.http(status, String(decoding: data, as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: item helpers (base64 for binary `B` values)

    static func binaryValue(_ bytes: [UInt8]) -> [String: String] { ["B": Data(bytes).base64EncodedString()] }
    static func stringValue(_ s: String) -> [String: String] { ["S": s] }
    static func numberValue(_ n: Int64) -> [String: String] { ["N": String(n)] }

    static func decodeBinary(_ attr: Any?) -> [UInt8]? {
        guard let dict = attr as? [String: Any], let b64 = dict["B"] as? String,
              let data = Data(base64Encoded: b64) else { return nil }
        return [UInt8](data)
    }
    static func decodeNumber(_ attr: Any?) -> Int64? {
        guard let dict = attr as? [String: Any], let n = dict["N"] as? String else { return nil }
        return Int64(n)
    }
}

// MARK: - KV over DynamoDB

/// A durable KV store over a DynamoDB table (`pk` string key, `val` binary).
public struct DynamoKVStore: Sendable {
    let db: DynamoDB
    let table: String

    public init(db: DynamoDB, table: String) { self.db = db; self.table = table }

    public func get(_ key: String) async -> [UInt8]? {
        let response = try? await db.call("GetItem", [
            "TableName": table,
            "Key": ["pk": DynamoDB.stringValue(key)],
        ])
        guard let item = response?["Item"] as? [String: Any] else { return nil }
        // TTL deletion is eventual, so honor an elapsed expiry client-side too.
        if let ttl = DynamoDB.decodeNumber(item["ttl"]), ttl <= Int64(Date().timeIntervalSince1970) {
            return nil
        }
        return DynamoDB.decodeBinary(item["val"])
    }

    public func put(_ key: String, _ value: [UInt8], expiresAt: Int?) async {
        var item: [String: Any] = ["pk": DynamoDB.stringValue(key), "val": DynamoDB.binaryValue(value)]
        // `expiresAt` is absolute epoch seconds — exactly DynamoDB's `ttl` attribute,
        // so a revoked-session entry self-evicts instead of accumulating forever.
        if let expiresAt { item["ttl"] = DynamoDB.numberValue(Int64(expiresAt)) }
        _ = try? await db.call("PutItem", ["TableName": table, "Item": item])
    }
}

// MARK: - Cache over DynamoDB (native TTL + client-side expiry check)

/// An ephemeral cache over a DynamoDB table, using DynamoDB's `ttl` attribute for
/// server-side expiry (with a client-side check, since TTL deletion is eventual).
public struct DynamoCacheStore: CacheStore {
    let db: DynamoDB
    let table: String

    public init(db: DynamoDB, table: String) { self.db = db; self.table = table }

    public func get(_ key: String) async throws -> [UInt8]? {
        let response = try await db.call("GetItem", [
            "TableName": table,
            "Key": ["pk": DynamoDB.stringValue(key)],
        ])
        guard let item = response["Item"] as? [String: Any] else { return nil }
        if let ttl = DynamoDB.decodeNumber(item["ttl"]), ttl <= Int64(Date().timeIntervalSince1970) {
            return nil   // expired but not yet swept
        }
        return DynamoDB.decodeBinary(item["val"])
    }

    public func set(_ key: String, _ value: [UInt8], ttlSeconds: Int?) async throws {
        var item: [String: Any] = ["pk": DynamoDB.stringValue(key), "val": DynamoDB.binaryValue(value)]
        if let ttlSeconds {
            item["ttl"] = DynamoDB.numberValue(Int64(Date().timeIntervalSince1970) + Int64(ttlSeconds))
        }
        _ = try await db.call("PutItem", ["TableName": table, "Item": item])
    }

    public func delete(_ key: String) async throws {
        _ = try await db.call("DeleteItem", [
            "TableName": table,
            "Key": ["pk": DynamoDB.stringValue(key)],
        ])
    }
}

// MARK: - Drivers (called by the generated aws composition)

public enum DynamoKVDriver {
    public static func connect(table: String, region: String, accessKey: String,
                               secretKey: String, endpoint: String? = nil) -> KV {
        let store = DynamoKVStore(db: DynamoDB(region: region, accessKey: accessKey,
                                               secretKey: secretKey, endpoint: endpoint), table: table)
        return KV(get: { await store.get($0) },
                  putExpiring: { key, value, expiresAt in await store.put(key, value, expiresAt: expiresAt) })
    }
}

public enum DynamoCacheDriver {
    public static func connect(table: String, region: String, accessKey: String,
                               secretKey: String, endpoint: String? = nil) -> Cache {
        Cache(DynamoCacheStore(db: DynamoDB(region: region, accessKey: accessKey,
                                            secretKey: secretKey, endpoint: endpoint), table: table))
    }
}

extension String {
    /// Drop a single trailing slash so `endpoint + "/path"` never doubles it.
    func trimmingSlash() -> String { hasSuffix("/") ? String(dropLast()) : self }
}
