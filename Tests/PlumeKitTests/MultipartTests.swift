import Testing
@testable import PlumeCore
import PlumeServer

private func multipartBody(boundary: String) -> [UInt8] {
    let crlf = "\r\n"
    var s = ""
    s += "--\(boundary)\(crlf)"
    s += "Content-Disposition: form-data; name=\"title\"\(crlf)\(crlf)"
    s += "Hello & <World>\(crlf)"
    s += "--\(boundary)\(crlf)"
    s += "Content-Disposition: form-data; name=\"avatar\"; filename=\"a.txt\"\(crlf)"
    s += "Content-Type: text/plain\(crlf)\(crlf)"
    s += "FILE-CONTENT-123\(crlf)"
    s += "--\(boundary)--\(crlf)"
    return Array(s.utf8)
}

@Test func multipartParsesFieldsAndFile() throws {
    let form = MultipartForm(body: multipartBody(boundary: "XB"), boundary: "XB")
    #expect(form != nil)
    #expect(form?["title"] == "Hello & <World>")
    let file = form?.file("avatar")
    #expect(file?.filename == "a.txt")
    #expect(file?.contentType == "text/plain")
    #expect(decodeUTF8(file!.body) == "FILE-CONTENT-123")
    #expect(form?.file("title") == nil)   // not a file
}

@Test func multipartFileStreamsToStorageDriver() async throws {
    let form = MultipartForm(body: multipartBody(boundary: "XB"), boundary: "XB")!
    let storage = NativeDrivers.memoryStorage()
    let (fields, files) = try await form.upload(to: storage)

    #expect(fields["title"] == "Hello & <World>")   // field round-tripped
    #expect(files.count == 1)
    #expect(files[0].field == "avatar")
    #expect(files[0].size == 16)

    // handler gets a reference; the bytes live in the blob store.
    let stored = try await storage.get(files[0].key)
    #expect(stored != nil)
    #expect(decodeUTF8(stored!) == "FILE-CONTENT-123")
}

@Test func requestMultipartUsesContentTypeBoundary() {
    var headers = Headers()
    headers.set("content-type", "multipart/form-data; boundary=XB")
    let request = Request(method: .post, path: "/upload", headers: headers, body: multipartBody(boundary: "XB"))
    let form = request.multipart()
    #expect(form?["title"] == "Hello & <World>")
}

@Test func fieldNameNotParsedFromFilename() {
    // A reordered Content-Disposition (filename before name) must not return the
    // filename as the field name.
    let disp = Array(#"form-data; filename="foo.txt"; name="field""#.utf8)
    #expect(quotedAttribute(disp, "name") == "field")
    #expect(quotedAttribute(disp, "filename") == "foo.txt")
}
