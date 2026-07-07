import Testing
import Foundation
@testable import PlumeCore
@testable import PlumeAWS

// The Lambda front-end's event mapping, verified OFFLINE with real API Gateway
// proxy event JSON — the SAME Application runs; only the entry differs.
@Test func lambdaMapsAPIGatewayV2EventThroughTheApp() async {
    let app = Application()
    app.get("/hello") { request in .text("hi " + (request.queryParams["name"] ?? "?")) }

    let event = """
    {"version":"2.0","rawPath":"/hello","rawQueryString":"name=ada",
     "headers":{"content-type":"text/plain"},
     "requestContext":{"http":{"method":"GET"}},
     "isBase64Encoded":false}
    """
    let request = LambdaAdapter.makeRequest(eventJSON: Data(event.utf8), context: .empty)
    #expect(request.method == .get)
    #expect(request.path == "/hello")
    #expect(request.query == "name=ada")

    let response = await app.handle(request)
    let object = try! JSONSerialization.jsonObject(with: LambdaAdapter.responseJSON(response)) as! [String: Any]
    #expect(object["statusCode"] as? Int == 200)
    #expect(object["body"] as? String == "hi ada")
    #expect(object["isBase64Encoded"] as? Bool == false)
}

@Test func lambdaDecodesBase64RequestBody() async {
    let app = Application()
    app.post("/echo") { request in .text(request.bodyText) }

    let body = Data("hello-bytes".utf8).base64EncodedString()
    let event = """
    {"version":"2.0","rawPath":"/echo","rawQueryString":"",
     "requestContext":{"http":{"method":"POST"}},
     "body":"\(body)","isBase64Encoded":true}
    """
    let request = LambdaAdapter.makeRequest(eventJSON: Data(event.utf8), context: .empty)
    #expect(request.method == .post)
    let response = await app.handle(request)
    let object = try! JSONSerialization.jsonObject(with: LambdaAdapter.responseJSON(response)) as! [String: Any]
    #expect(object["body"] as? String == "hello-bytes")
}
