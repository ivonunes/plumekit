import Testing
@testable import PlumeRuntime

@Test func defaultedTreatsPresentButEmptyOptionalAsMissing() {
    #expect(Plume.defaulted(Optional<String>.some(""), "X") == "X")      // present-but-empty → fallback
    #expect(Plume.defaulted(Optional<String>.some("hi"), "X") == "hi")
    #expect(Plume.defaulted(Optional<String>.none, "X") == "X")
    #expect(Plume.defaulted(Optional<[Int]>.some([]), [9]) == [9])
    #expect(Plume.defaulted(Optional<[Int]>.some([1]), [9]) == [1])
}
