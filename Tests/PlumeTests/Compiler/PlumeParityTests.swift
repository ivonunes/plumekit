//
//  PlumeParityTests.swift
//  PlumeTests — compiling back-end
//
//  A parity harness: render the SAME component through BOTH back-ends — the
//  interpreter (`PlumeTemplate`) and the compiling back-end (via `RenderHarness`) —
//  and assert byte-identical output. This systematically pins the two-renderer
//  contract that the fixed render gate only spot-checks.
//
//  Each case supplies the component body, its parameters (untyped for the
//  interpreter, typed for the compiler), and a literal argument list used verbatim
//  by both. Cases in `knownDivergent` are documented, not asserted (each is a
//  tracked bug); everything else must match.
//

import Testing

@testable import Plume

@Suite struct PlumeParityTests {
    struct ParityCase {
        let name: String
        let interpParams: String   // e.g. "count"
        let compParams: String     // e.g. "count: Int"
        let body: String
        let args: String           // e.g. "count: 0" — verbatim in both back-ends
    }

    /// Constructs to probe for compiler↔interpreter divergence.
    static let cases: [ParityCase] = [
        .init(name: "text", interpParams: "name", compParams: "name: String",
              body: "<p>{name}</p>", args: #"name: "Ann & <Bob>""#),
        .init(name: "int", interpParams: "n", compParams: "n: Int",
              body: "<b>{n}</b>", args: "n: 42"),
        .init(name: "intZero", interpParams: "n", compParams: "n: Int",
              body: "@if n {yes} else {no}", args: "n: 0"),
        .init(name: "doubleSimple", interpParams: "d", compParams: "d: Double",
              body: "<s>{d}</s>", args: "d: 3.14159"),
        .init(name: "doubleWhole", interpParams: "d", compParams: "d: Double",
              body: "<s>{d}</s>", args: "d: 5.0"),
        .init(name: "doubleThird", interpParams: "d", compParams: "d: Double",
              body: "<s>{d}</s>", args: "d: 1.5"),
        .init(name: "doublePrice", interpParams: "d", compParams: "d: Double",
              body: "<s>{d}</s>", args: "d: 19.99"),
        .init(name: "doubleRatio", interpParams: "d", compParams: "d: Double",
              body: "<s>{d}</s>", args: "d: 100.1"),
        .init(name: "boolTrue", interpParams: "b", compParams: "b: Bool",
              body: "@if b {on} else {off}", args: "b: true"),
        .init(name: "defaultEmptyString", interpParams: "s", compParams: "s: String",
              body: #"{s | default("X")}"#, args: #"s: """#),
        .init(name: "escapeThenRaw", interpParams: "s", compParams: "s: String",
              body: "{s | escape | raw}", args: #"s: "a<b>c""#),
        .init(name: "ifFalseString", interpParams: "s", compParams: "s: String",
              body: "@if s {yes} else {no}", args: #"s: "false""#),
        .init(name: "defaultOnFalse", interpParams: "b", compParams: "b: Bool",
              body: #"{b | default(true)}"#, args: "b: false"),
        .init(name: "condClassZero", interpParams: "n", compParams: "n: Int",
              body: #"<div class="base" class:on="{n}">x</div>"#, args: "n: 0"),
        .init(name: "dividedByFraction", interpParams: "n", compParams: "n: Int",
              body: "{n | dividedBy(4)}", args: "n: 10"),     // 2.5, not 2 (integer truncation)
        .init(name: "dividedByWhole", interpParams: "n", compParams: "n: Int",
              body: "{n | dividedBy(2)}", args: "n: 8"),      // 4, not 4.0
        .init(name: "dividedByZero", interpParams: "n", compParams: "n: Int",
              body: "{n | dividedBy(0)}", args: "n: 10"),     // 0, not a divide-by-zero trap
        .init(name: "moduloBasic", interpParams: "n", compParams: "n: Int",
              body: "{n | modulo(3)}", args: "n: 10"),        // 1
        .init(name: "roundPrecision", interpParams: "d", compParams: "d: Double",
              body: "{d | round(2)}", args: "d: 3.14159"),    // 3.14 (precision honored)
        .init(name: "arrayLiteralTernary", interpParams: "b", compParams: "b: Bool",
              body: #"@for c in ["card", b ? "on" : "off"] {<i>{c}</i>}"#, args: "b: true"),
    ]

    /// Divergences intentionally not asserted (each a tracked bug). Add a name to
    /// document one; remove it once fixed so the harness starts guarding it. Empty —
    /// the whole backlog is fixed and now guarded here.
    static let knownDivergent: Set<String> = []

    @Test func compilerAndInterpreterAgree() throws {
        // One batched compile+run for all cases (fast); interpreter renders in-process.
        let renderCases = Self.cases.map {
            RenderCase(
                name: $0.name,
                template: "@component \(cap($0.name))(\($0.compParams)) {\($0.body)}",
                call: "\(lower($0.name))(\($0.args), into: &out)")
        }
        let compiled = try RenderHarness.render(cases: renderCases, fixtures: "", target: .native)

        var divergences: [String] = []
        for c in Self.cases {
            let interp = try PlumeTemplate(
                "@component \(cap(c.name))(\(c.interpParams)) {\(c.body)}@\(cap(c.name))(\(c.args))"
            ).render([:])
            let comp = String(decoding: compiled[c.name] ?? [], as: UTF8.self)
            if interp != comp {
                divergences.append("  [\(c.name)] interp=\(quoted(interp)) compiled=\(quoted(comp))")
                if !Self.knownDivergent.contains(c.name) {
                    Issue.record("Parity divergence in '\(c.name)': interp=\(quoted(interp)) compiled=\(quoted(comp))")
                }
            } else {
                #expect(!Self.knownDivergent.contains(c.name), "'\(c.name)' now agrees — drop it from knownDivergent")
            }
        }
        if !divergences.isEmpty {
            print("PARITY DIVERGENCES (\(divergences.count)):\n" + divergences.joined(separator: "\n"))
        }
    }

    private func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    private func lower(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
    private func quoted(_ s: String) -> String { "\"" + s + "\"" }
}
