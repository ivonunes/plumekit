import Testing
@testable import PlumeCore

@Test func jsonSerializeRoundTrips() {
    let value = JSONValue.object([
        ("id", .int(7)),
        ("title", .string("Hello \"World\"\n& <x>")),   // needs escaping
        ("published", .bool(true)),
        ("score", .double(2.5)),
        ("tags", .array([.string("a"), .string("b")])),
        ("nothing", .null),
    ])
    let parsed = parseJSON(value.serialize())
    #expect(parsed != nil)
    #expect(parsed?["id"]?.intValue == 7)
    #expect(parsed?["title"]?.stringValue == "Hello \"World\"\n& <x>")
    #expect(parsed?["published"]?.boolValue == true)
    #expect(parsed?["score"]?.doubleValue == 2.5)
    #expect(parsed?["tags"]?.arrayValue?.count == 2)
    if case .null = parsed?["nothing"] {} else { Issue.record("null") }
}

@Test func jsonParsesClientPayload() {
    let parsed = parseJSON("  { \"title\": \"Hi\", \"views\": 42, \"ok\": false }  ")
    #expect(parsed?["title"]?.stringValue == "Hi")
    #expect(parsed?["views"]?.intValue == 42)
    #expect(parsed?["ok"]?.boolValue == false)
    #expect(parsed?["missing"] == nil)
}

@Test func jsonParsesUnicodeEscapeAndUTF8() {
    #expect(parseJSON("\"\\u0041\\u00e9\"")?.stringValue == "Aé")   // \u escapes
    #expect(parseJSON("\"caf\u{00e9} & <ok>\"")?.stringValue == "café & <ok>")  // raw UTF-8
}

@Test func jsonRejectsMalformed() {
    #expect(parseJSON("{not json") == nil)
    #expect(parseJSON("[1, 2,") == nil)
}

@Test func jsonParserBoundsHugeExponent() {
    // A pathological exponent must not spin billions of iterations or overflow/trap.
    #expect(parseJSON(#"{"x": 1e2000000000}"#) != nil)
    #expect(parseJSON(#"{"x": 1e-2000000000}"#) != nil)
}
