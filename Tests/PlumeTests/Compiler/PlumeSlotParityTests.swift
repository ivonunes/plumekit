import Testing
@testable import Plume

/// The slot-fallback decision must agree between back-ends: a provided slot that
/// renders EMPTY shows the fallback (not just an absent slot).
@Suite struct PlumeSlotParityTests {
    private func compiled(_ box: String, _ wrapper: String, _ call: String) throws -> String {
        let bytes = try RenderHarness.render(
            cases: [RenderCase(name: "w", template: box + "\n" + wrapper, call: call)],
            fixtures: "", target: .native)["w"] ?? []
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func emptyProvidedSlotFallsBackInBothBackends() throws {
        let box = "@component Box() {<b>@slot { FB }</b>}"
        let wrapper = "@component Wrapper(x: String) {@Box() {{x}}}"      // no whitespace around {x}
        let iwrapper = "@component Wrapper(x) {@Box() {{x}}}"

        // Empty content → the rendered slot is empty → fallback, in BOTH back-ends.
        let cEmpty = try compiled(box, wrapper, #"wrapper(x: "", into: &out)"#)
        let iEmpty = try PlumeTemplate(box + iwrapper + #"@Wrapper(x: "")"#).render([:])
        #expect(cEmpty == iEmpty)
        #expect(cEmpty.contains("FB"))

        // Non-empty content → the content shows (no fallback), in both.
        let cFull = try compiled(box, wrapper, #"wrapper(x: "hi", into: &out)"#)
        let iFull = try PlumeTemplate(box + iwrapper + #"@Wrapper(x: "hi")"#).render([:])
        #expect(cFull == iFull)
        #expect(cFull.contains("hi") && !cFull.contains("FB"))
    }
}
