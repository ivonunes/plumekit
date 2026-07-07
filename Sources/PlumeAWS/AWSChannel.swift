import Foundation
import PlumeCore

// Production ports for the API Gateway WebSocket channel: DynamoDB for per-channel
// state + the connection registry, and the API Gateway Management API
// (postToConnection) for fan-out. Both endpoints are overridable for LocalStack.
// The channel adapter logic itself (APIGatewayChannelHandler) is platform-agnostic;
// these ports are the only AWS-specific glue.
//
// One table, partition key `channel` (S) + sort key `sk` (S):
//   • state item:      sk = "state#<key>",   attribute `val` (B)
//   • connection item: sk = "conn#<connID>", attribute `kind` (N)

public enum AWSChannelPorts {
    /// Build the ports from a DynamoDB table (state + connections) and the API
    /// Gateway Management endpoint (`https://<api-id>.execute-api.<region>.amazonaws.com/<stage>`).
    public static func make(
        region: String, accessKey: String, secretKey: String,
        table: String, managementEndpoint: String, endpoint: String? = nil
    ) -> APIGatewayChannelPorts {
        let db = DynamoDB(region: region, accessKey: accessKey, secretKey: secretKey, endpoint: endpoint)
        let mgmt = managementEndpoint.trimmingSlash()
        let apiSigner = SigV4(region: region, service: "execute-api",
                              accessKey: accessKey, secretKey: secretKey)

        return APIGatewayChannelPorts(
            loadState: { channel in
                let items = await query(db, table: table, channel: channel, prefix: "state#")
                return items.compactMap { item in
                    guard let sk = skValue(item), let value = DynamoDB.decodeBinary(item["val"])
                    else { return nil }
                    return (key: String(sk.dropFirst("state#".count)), value: value)
                }
            },
            saveState: { channel, kvs in
                for (key, value) in kvs {
                    _ = try? await db.call("PutItem", [
                        "TableName": table,
                        "Item": [
                            "channel": DynamoDB.stringValue(channel),
                            "sk": DynamoDB.stringValue("state#" + key),
                            "val": DynamoDB.binaryValue(value),
                        ],
                    ])
                }
            },
            connections: { channel in
                let items = await query(db, table: table, channel: channel, prefix: "conn#")
                return items.compactMap { item -> ChannelConnection? in
                    guard let sk = skValue(item) else { return nil }
                    let kind = DynamoDB.decodeNumber(item["kind"])
                        .flatMap { PayloadKind(rawValue: UInt8(truncatingIfNeeded: $0)) } ?? .fragment
                    return ChannelConnection(connectionID: String(sk.dropFirst("conn#".count)), kind: kind)
                }
            },
            post: { connectionID, bytes in
                let encoded = connectionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? connectionID
                _ = try? await AWSHTTP.send(
                    signer: apiSigner, method: "POST",
                    urlString: mgmt + "/@connections/" + encoded, body: Data(bytes))
            }
        )
    }

    private static func skValue(_ item: [String: Any]) -> String? {
        (item["sk"] as? [String: Any])?["S"] as? String
    }

    private static func query(_ db: DynamoDB, table: String, channel: String, prefix: String) async -> [[String: Any]] {
        let response = try? await db.call("Query", [
            "TableName": table,
            "KeyConditionExpression": "channel = :c AND begins_with(sk, :p)",
            "ExpressionAttributeValues": [
                ":c": DynamoDB.stringValue(channel),
                ":p": DynamoDB.stringValue(prefix),
            ],
        ])
        return (response?["Items"] as? [[String: Any]]) ?? []
    }
}
