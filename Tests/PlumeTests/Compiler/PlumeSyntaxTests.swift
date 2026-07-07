//
//  PlumeSyntaxTests.swift
//  PlumeTests — syntax Swiftification (interpreting renderer side)
//
//  `??` and `@if let` must mean the same thing in both back-ends. These pin the
//  interpreting renderer's semantics; the compiling back-end's are proven by
//  PlumeCompiledRenderTests with the identical templates.
//

import Testing

@testable import Plume

@Suite struct PlumeSyntaxTests {
    @Test func nilCoalescingFallsBackOnMissing() throws {
        let template = try PlumeTemplate(#"<p>{name ?? "Anon"}</p>"#)
        #expect(try template.render(["name": "Bob"]) == "<p>Bob</p>")
        #expect(try template.render([:]) == "<p>Anon</p>")
    }

    @Test func nilCoalescingKeepsEmptyStringValue() throws {
        // Like Swift `??`, an empty string is a value — only nil/null coalesces.
        let template = try PlumeTemplate(#"<p>{name ?? "Anon"}|</p>"#)
        #expect(try template.render(["name": ""]) == "<p>|</p>")
    }

    @Test func nilCoalescingIsHigherPrecedenceThanComparison() throws {
        // `a ?? b == c` parses as `(a ?? b) == c`, matching Swift.
        let template = try PlumeTemplate(#"@if (missing ?? "x") == "x" {yes} else {no}"#)
        #expect(try template.render([:]) == "yes")
    }

    @Test func ifLetBindsWhenPresent() throws {
        let template = try PlumeTemplate(#"@if let n = name {Hi {n}} else {Bye}"#)
        #expect(try template.render(["name": "Bob"]) == "Hi Bob")
        #expect(try template.render([:]) == "Bye")
    }

    @Test func bangBindsTighterThanComparison() throws {
        // Plume 2.0 aligns precedence with Swift: `!a == b` is `(!a) == b`, not
        // the pre-2.0 `!(a == b)`. With count=1: (!1)==true → false==true → false.
        let template = try PlumeTemplate("@if !count == true {yes} else {no}")
        #expect(try template.render(["count": 1]) == "no")
    }

    @Test func ifLetElseIfChain() throws {
        let template = try PlumeTemplate(
            #"@if let a = first {A {a}} else if let b = second {B {b}} else {none}"#)
        #expect(try template.render(["second": "two"]) == "B two")
        #expect(try template.render(["first": "one"]) == "A one")
        #expect(try template.render([:]) == "none")
    }

    // MARK: - Formatter alias canonicalisation

    @Test func formatterCanonicalisesFilterAndMethodAliases() {
        #expect(PlumeFormatter.format("<p>{name | upcase}</p>") == "<p>{name | uppercased}</p>\n")
        #expect(PlumeFormatter.format("<p>{t | downcase}</p>") == "<p>{t | lowercased}</p>\n")
        #expect(PlumeFormatter.format(#"{p.startsWith("/")}"#) == "{p.hasPrefix(\"/\")}\n")
        #expect(PlumeFormatter.format(#"{p.endsWith(".md")}"#) == "{p.hasSuffix(\".md\")}\n")
    }

    @Test func formatterCanonicalisesNullToNil() {
        #expect(PlumeFormatter.format("<p>{v ?? null}</p>") == "<p>{v ?? nil}</p>\n")
    }

    @Test func formatterPreservesStringLiterals() {
        // Alias words inside string literals must not be rewritten.
        #expect(
            PlumeFormatter.format(#"<p>{"please upcase this"}</p>"#)
                == "<p>{\"please upcase this\"}</p>\n")
    }

    @Test func formatterCanonicalisesSlotNaming() {
        #expect(
            PlumeFormatter.format("@slot(name: header) {\nx\n}")
                == "@slot(header) {\n  x\n}\n")
    }
}
