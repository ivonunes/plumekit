import Testing
@testable import PlumeCore

@Test func jsonDecodesSurrogatePairsToAstralChars() {
    // 😀 = 😀 (U+1F600)
    let v = parseJSON("\"a\\uD83D\\uDE00b\"")
    #expect(v?.stringValue == "a😀b")
    // lone high surrogate → replacement char, not corrupt bytes
    let lone = parseJSON("\"\\uD83D\"")
    #expect(lone?.stringValue == "\u{FFFD}")
}

@Test func jsonRejectsPathologicallyDeepNestingWithoutCrashing() {
    let deep = String(repeating: "[", count: 100_000)
    #expect(parseJSON(deep) == nil)          // rejected, not a stack overflow
    // A reasonable depth still parses.
    let ok = "[[[[[[1]]]]]]"
    #expect(parseJSON(ok) != nil)
}
