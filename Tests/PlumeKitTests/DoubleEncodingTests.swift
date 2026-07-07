import Testing
import PlumeCore
import PlumeRuntime

@Suite struct DoubleEncodingTests {
    private func json(_ value: JSONValue) -> String {
        String(decoding: value.serialize(), as: UTF8.self)
    }

    @Test func jsonEncodesOrdinaryDoubles() {
        #expect(json(.double(1.5)) == "1.5")
        #expect(json(.double(-0.25)) == "-0.25")
        #expect(json(.double(3.0)) == "3.0")
        #expect(json(.double(0.1)).hasPrefix("0.1"))
    }

    @Test func jsonEncodesHugeAndSpecialDoublesWithoutTrapping() {
        #expect(json(.double(1e19)).contains("e"))          // exponent form, no trap
        #expect(json(.double(Double.greatestFiniteMagnitude)).contains("e"))
        #expect(json(.double(Double.nan)) == "null")        // JSON has no NaN
        #expect(json(.double(.infinity)) == "null")
        #expect(json(.double(-.infinity)) == "null")
    }

    @Test func htmlRendersHugeDoublesWithoutTrapping() {
        var out = HTML()
        out.text(1e19)
        let rendered = String(decoding: out.bytes, as: UTF8.self)
        #expect(rendered.contains("e"))
        var out2 = HTML()
        out2.text(2.5)
        #expect(String(decoding: out2.bytes, as: UTF8.self) == "2.5")
    }
}
