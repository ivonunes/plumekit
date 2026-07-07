import Testing
import Foundation
@testable import PlumeCore
@testable import PlumeAWS

// The AWS front-end + adapters, exercised offline. Over-the-wire behaviour (real
// SigV4 calls to S3/SQS/SSM/DynamoDB/SES) is covered by the gated LocalStack
// integration script; here we test the pure event mapping and the DynamoDB codec.

@Test func lambdaMapsHTTPApiV2EventToResponse() async throws {
    let app = Application()
    app.get("/hello/:name") { request in
        .text("hi \(request.parameters["name"] ?? "")")
    }
    let event = Data("""
    {"requestContext":{"http":{"method":"GET"}},"rawPath":"/hello/ada","rawQueryString":""}
    """.utf8)

    let responseData = await LambdaAdapter.processInvocation(app, context: .empty, eventJSON: event)
    let object = try #require(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    #expect(object["statusCode"] as? Int == 200)
    #expect(object["body"] as? String == "hi ada")
    #expect(object["isBase64Encoded"] as? Bool == false)
}

@Test func lambdaMapsRestApiV1Event() async throws {
    let app = Application()
    app.get("/ping") { _ in .text("pong") }
    let event = Data(#"{"httpMethod":"GET","path":"/ping"}"#.utf8)

    let responseData = await LambdaAdapter.processInvocation(app, context: .empty, eventJSON: event)
    let object = try #require(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    #expect(object["statusCode"] as? Int == 200)
    #expect(object["body"] as? String == "pong")
}

@Test func lambdaBase64EncodesBinaryResponseBodies() async throws {
    let app = Application()
    app.get("/bin") { _ in Response(body: [0, 1, 2, 255]) }
    let event = Data(#"{"httpMethod":"GET","path":"/bin"}"#.utf8)

    let responseData = await LambdaAdapter.processInvocation(app, context: .empty, eventJSON: event)
    let object = try #require(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    #expect(object["isBase64Encoded"] as? Bool == true)
    #expect(object["body"] as? String == Data([0, 1, 2, 255]).base64EncodedString())
}

@Test func dynamoDBEncodesAndDecodesAttributes() {
    // Binary values round-trip through base64 `B` attributes.
    let encoded = DynamoDB.binaryValue([1, 2, 3, 255])
    #expect(encoded["B"] == Data([1, 2, 3, 255]).base64EncodedString())
    #expect(DynamoDB.decodeBinary(["B": Data([1, 2, 3, 255]).base64EncodedString()]) == [1, 2, 3, 255])

    // Numbers (used for cache TTL + connection kind) round-trip through `N`.
    #expect(DynamoDB.numberValue(1_700_000_000) == ["N": "1700000000"])
    #expect(DynamoDB.decodeNumber(["N": "42"]) == 42)

    // Absent / malformed attributes decode to nil, not a crash.
    #expect(DynamoDB.decodeBinary(nil) == nil)
    #expect(DynamoDB.decodeNumber(["S": "not-a-number"]) == nil)
}
