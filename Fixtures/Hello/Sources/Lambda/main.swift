import Foundation
import App
import PlumeCore
import PlumeAWS

// AWS Lambda entry — the third front-end (alongside Server/NIO and Worker/Wasm),
// running the SAME buildApp()/buildChannel() from the App module, UNCHANGED. The AWS
// composition root is GENERATED from plumekit.toml's [targets.aws] profile by the
// PlumeKitCodegen plugin (Composition.awsContext) — exactly as Server/main.swift uses
// Composition.nativeContext. Config (region, keys, resource names, and an optional
// AWS_ENDPOINT_URL for LocalStack) comes from the environment.
let env = ProcessInfo.processInfo.environment

let base: Context
do {
    base = try Composition.awsContext()
} catch {
    FileHandle.standardError.write(Data("plumekit(lambda): failed to build AWS context: \(error)\n".utf8))
    exit(1)
}

// Model-driven broadcasting → API Gateway WebSockets (the third Channel adapter).
// Real ports (DynamoDB + postToConnection) when a channel table + management
// endpoint are configured; no-op otherwise, so the function still serves plain HTTP.
let region = env["AWS_REGION"] ?? "us-east-1"
let ports: APIGatewayChannelPorts
if let table = env["CHANNEL_TABLE"], let management = env["CHANNEL_MGMT_ENDPOINT"] {
    ports = AWSChannelPorts.make(
        region: region,
        accessKey: env["AWS_ACCESS_KEY_ID"] ?? "", secretKey: env["AWS_SECRET_ACCESS_KEY"] ?? "",
        table: table, managementEndpoint: management, endpoint: env["AWS_ENDPOINT_URL"])
} else {
    ports = APIGatewayChannelPorts(loadState: { _ in [] }, saveState: { _, _ in },
                                   connections: { _ in [] }, post: { _, _ in })
}
let channel = APIGatewayChannelHandler(ports: ports) { message, context in
    try await buildChannel().onMessage(message, context)   // SAME Channel as the DO + native hub
}
let broadcaster = Broadcaster { id, pushes in
    await channel.broadcast(channel: id.value, pushes: pushes)
}
let context = base.adding(broadcaster: broadcaster)

// The Lambda custom-runtime loop (executes only inside Lambda).
try await LambdaAdapter.run(buildApp(), context: context)
