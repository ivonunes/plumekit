import Testing
@testable import PlumeRuntime

// The compiled back-end's byte-wise appendDouble must match the interpreter's
// String(Double) (shortest round-trip) across the realistic range, so the two
// renderers agree on any Double. |exponent| > 22 is out of scope (see appendDouble).
@Test func appendDoubleMatchesStringDouble() {
    func rendered(_ d: Double) -> String {
        var h = HTML(); h.appendDouble(d); return String(decoding: h.bytes, as: UTF8.self)
    }
    let values: [Double] = [
        0, -0.0, 1, -1, 5.0, 3.14159, -3.14159, 1.5, 0.1, 0.2, 0.3, 100.0, 100.1,
        1.005, 1.0 / 3.0, 2.0 / 3.0, 0.001, 0.0001, 0.00001, 1234.5678, 999999.0,
        123456789012345.0, 1e15, 1e16, 1e20, 1e-5, 1e-7, 1.23e-10, 42.0, 0.5,
        9.999999, 0.99999999, 1e-22, 1e22, 0.125, 255.255, -0.0007, 3.0, 10.0,
    ]
    for v in values {
        #expect(rendered(v) == String(v), "appendDouble(\(v)) = \(rendered(v)), want \(String(v))")
    }
}
