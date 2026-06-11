import XCTest

@testable import Plume

/// Table-driven coverage for every filter implemented in PlumeRendererFilters.swift
/// (plus the `raw`/`escape`/`escape_once` pseudo-filters handled in expression
/// evaluation). Each row renders a real template against a context and compares
/// the full output.
final class PlumeFilterTests: XCTestCase {
    private typealias FilterCase = (template: String, context: [String: Any], expected: String)

    private func assertRenders(
        _ cases: [FilterCase], file: StaticString = #filePath, line: UInt = #line
    ) {
        for entry in cases {
            do {
                let template = try PlumeTemplate(entry.template)
                let html = try template.render(entry.context)
                XCTAssertEqual(
                    html, entry.expected, "Template: \(entry.template)", file: file, line: line)
            } catch {
                XCTFail("Template \(entry.template) threw: \(error)", file: file, line: line)
            }
        }
    }

    func testDefaultFilterKeepsZeroAndDistinguishesEmptyFromNil() {
        assertRenders([
            // Recently fixed: 0 and 0.0 are values, not "missing".
            ("{count | default(5)}", ["count": 0], "0"),
            ("{count | default(5)}", ["count": 0.0], "0.0"),
            ("{count | default(5)}", ["count": 7], "7"),
            // Missing, empty string, false, and empty array fall back.
            ("{count | default(5)}", [:], "5"),
            ("{count | default(5)}", ["count": ""], "5"),
            ("{count | default(5)}", ["count": false], "5"),
            ("{count | default(5)}", ["count": [Any]()], "5"),
            ("{name | default(\"anonymous\")}", ["name": "Ivo"], "Ivo"),
            ("{name | default(\"anonymous\")}", [:], "anonymous"),
            // No argument: falls back to nothing rather than crashing.
            ("{name | default}", [:], ""),
        ])
    }

    func testDateFilters() {
        let iso = "2026-05-10T18:30:00Z"
        assertRenders([
            ("{d | date}", ["d": iso], "2026-05-10"),
            ("{d | date(\"d MMMM yyyy\")}", ["d": iso], "10 May 2026"),
            // Liquid-style strftime tokens are translated.
            ("{d | date(\"%d/%m/%Y\")}", ["d": iso], "10/05/2026"),
            ("{d | dateToXMLSchema}", ["d": iso], "2026-05-10T18:30:00Z"),
            ("{d | dateToRFC822}", ["d": iso], "Sun, 10 May 2026 18:30:00 +0000"),
            ("{d | dateToString}", ["d": iso], "10 May 2026"),
            ("{d | dateToString}", ["d": "2026-01-02"], "02 Jan 2026"),
            ("{d | dateToLongString}", ["d": "2026-01-02"], "02 January 2026"),
            // Space-separated date-times parse too.
            ("{d | dateToString}", ["d": "2026-01-02 08:15:00"], "02 Jan 2026"),
            // Numbers are treated as Unix timestamps.
            ("{0 | dateToString}", [:], "01 Jan 1970"),
            // Unparseable input renders as empty rather than crashing.
            ("{d | date}", ["d": "not a date"], ""),
            ("{missing | dateToRFC822}", [:], ""),
        ])
    }

    func testStringFilters() {
        assertRenders([
            ("{\"a,b,c\" | split(\",\") | join(\"-\")}", [:], "a-b-c"),
            ("{\"\" | split(\",\") | size}", [:], "1"),
            ("{\"a-b-a\" | replace(\"a\", \"x\")}", [:], "x-b-x"),
            ("{\"a-b-a\" | replaceFirst(\"a\", \"x\")}", [:], "x-b-a"),
            ("{\"a-b-a\" | remove(\"a\")}", [:], "-b-"),
            ("{\"a-b-a\" | removeFirst(\"a\")}", [:], "-b-a"),
            ("{\"World\" | prepend(\"Hello \")}", [:], "Hello World"),
            ("{\"Hello\" | append(\"!\")}", [:], "Hello!"),
            ("{\"héllo\" | upcase}", [:], "HÉLLO"),
            ("{\"HÉLLO\" | downcase}", [:], "héllo"),
            ("{\"hELLO wORLD\" | capitalize}", [:], "Hello world"),
            ("{\"\" | capitalize}", [:], ""),
            // Non-string input is stringified, not rejected.
            ("{5 | upcase}", [:], "5"),
            ("{text | strip}", ["text": "  padded \n"], "padded"),
            ("{text | lstrip}", ["text": "  padded  "], "padded  "),
            ("{text | rstrip}", ["text": "  padded  "], "  padded"),
            ("{text | stripNewlines}", ["text": "a\nb\r\nc"], "abc"),
            ("{\"hello\" | reverse}", [:], "olleh"),
            ("{\"héllo🙂\" | reverse}", [:], "🙂olléh"),
            ("{\"Hello world\" | truncate(8)}", [:], "Hello..."),
            ("{\"Hello world\" | truncate(8, \"…\")}", [:], "Hello w…"),
            ("{\"Hi\" | truncate(8)}", [:], "Hi"),
            ("{\"one two three four\" | truncateWords(2)}", [:], "one two..."),
            ("{\"one two three\" | truncateWords(2, \"…\")}", [:], "one two…"),
            ("{\"one two\" | truncateWords(5)}", [:], "one two"),
            ("{\"Fish & Chips — Friday!\" | slugify}", [:], "fish-and-chips-friday"),
            // Non-ASCII letters are replaced, documenting the ASCII-only slug.
            ("{\"Café Crème\" | slug}", [:], "caf-cr-me"),
            ("{\"hello\" | slice(1)}", [:], "e"),
            ("{\"abcdef\" | slice(1, 3)}", [:], "bcd"),
            ("{\"hello\" | slice(-3, 2)}", [:], "ll"),
            ("{\"hello\" | slice(10, 2)}", [:], ""),
            ("{\"\" | slice(0, 2)}", [:], ""),
        ])
    }

    func testHTMLAndEncodingFilters() {
        assertRenders([
            // newlineToBR escapes the input first and is emitted as safe HTML.
            ("{text | newlineToBR}", ["text": "a<b\nc"], "a&lt;b<br>\nc"),
            ("{html | stripHTML}", ["html": "<p>Hello <em>world</em></p>"], "Hello world"),
            ("{\"/photos/a b.jpg\" | urlEncode}", [:], "%2Fphotos%2Fa%20b.jpg"),
            ("{\"%2Fa%20b\" | urlDecode}", [:], "/a b"),
            // Invalid percent escapes fall back to the original string.
            ("{\"100% sure\" | urlDecode}", [:], "100% sure"),
            ("{value | json}", ["value": ["b": 1, "a": "x"] as [String: Any]],
             #"{"a":"x","b":1}"#),
            ("{5 | json}", [:], "5"),
            ("{\"a\" | json}", [:], #""a""#),
            ("{flag | json}", ["flag": true], "true"),
            ("{values | json}", ["values": [1, 2]], "[1,2]"),
            ("{missing | json}", [:], "null"),
            ("{\"<b>\" | raw}", [:], "<b>"),
            ("{\"<b>\"}", [:], "&lt;b&gt;"),
            ("{\"<b>\" | escape}", [:], "&lt;b&gt;"),
            ("{text | escape_once}", ["text": "Fish &amp; <em>"], "Fish &amp; &lt;em&gt;"),
        ])
    }

    func testCollectionFilters() {
        let posts: [[String: Any]] = [
            ["title": "B", "order": 2, "published": true],
            ["title": "A", "order": 1, "published": false],
        ]
        assertRenders([
            ("{items | first}", ["items": ["a", "b", "c"]], "a"),
            ("{items | last}", ["items": ["a", "b", "c"]], "c"),
            ("{items | first}", ["items": [Any]()], ""),
            // first/last on non-arrays produce nothing instead of crashing.
            ("{title | first}", ["title": "abc"], ""),
            ("{posts | map(\"title\") | join(\",\")}", ["posts": posts], "B,A"),
            // Missing keys map to null and can be compacted away.
            ("{posts | map(\"missing\") | compact | size}", ["posts": posts], "0"),
            ("{title | map(\"x\") | size}", ["title": "abc"], "0"),
            ("{posts | where(\"published\") | map(\"title\") | join(\",\")}", ["posts": posts], "B"),
            ("{posts | where(\"title\", \"A\") | map(\"order\") | join(\",\")}", ["posts": posts], "1"),
            ("{posts | sort(\"title\") | map(\"title\") | join(\"\")}", ["posts": posts], "AB"),
            // sort compares stringified values; sortNatural compares naturally.
            ("{names | sort | join(\",\")}", ["names": ["item10", "item2"]], "item10,item2"),
            ("{names | sortNatural | join(\",\")}", ["names": ["item10", "item2"]], "item2,item10"),
            ("{items | reverse | join(\",\")}", ["items": ["a", "b"]], "b,a"),
            ("{words | unique | join(\",\")}", ["words": ["one", "two", "one"]], "one,two"),
            ("{mixed | compact | join(\",\")}", ["mixed": ["a", NSNull(), "b"] as [Any]], "a,b"),
            ("{items | concat([\"c\", \"d\"]) | join(\",\")}", ["items": ["a", "b"]], "a,b,c,d"),
            ("{items | concat(\"c\") | join(\",\")}", ["items": ["a", "b"]], "a,b,c"),
            // concat on a non-array passes the value through.
            ("{title | concat(\"x\")}", ["title": "abc"], "abc"),
            ("{items | join}", ["items": ["a", "b"]], "ab"),
            ("{title | join(\",\")}", ["title": "abc"], ""),
            ("{items | slice(0, 2) | join(\"-\")}", ["items": ["x", "y", "z"]], "x-y"),
            ("{items | size}", ["items": ["a", "b", "c"]], "3"),
            ("{meta | size}", ["meta": ["a": 1, "b": 2]], "2"),
            // size counts characters (not UTF-16 units) for strings.
            ("{\"🙂🙂\" | size}", [:], "2"),
            ("{missing | size}", [:], "0"),
        ])
    }

    func testMathFilters() {
        assertRenders([
            ("{-3.5 | abs}", [:], "3.5"),
            ("{0 | abs}", [:], "0"),
            ("{\"abc\" | abs}", [:], "0"),
            ("{1.2 | ceil}", [:], "2"),
            ("{-1.5 | ceil}", [:], "-1"),
            ("{1.8 | floor}", [:], "1"),
            ("{-1.5 | floor}", [:], "-2"),
            ("{2.5 | round}", [:], "3"),
            ("{2.4 | round}", [:], "2"),
            ("{3.14159 | round(2)}", [:], "3.14"),
            // Negative precision clamps to whole numbers.
            ("{2.7 | round(-1)}", [:], "3"),
            ("{10 | plus(5)}", [:], "15"),
            ("{\"3\" | plus(\"4.5\")}", [:], "7.5"),
            ("{5 | plus}", [:], "5"),
            ("{missing | plus(1)}", [:], "1"),
            ("{10 | minus(12)}", [:], "-2"),
            ("{6 | times(7)}", [:], "42"),
            ("{\"abc\" | times(3)}", [:], "0"),
            ("{7 | dividedBy(2)}", [:], "3.5"),
            ("{7 | dividedBy(0)}", [:], "0"),
            ("{7 | modulo(3)}", [:], "1"),
            ("{-7 | modulo(3)}", [:], "-1"),
            ("{7 | modulo(0)}", [:], "0"),
            ("{3 | atLeast(5)}", [:], "5"),
            ("{8 | atLeast(5)}", [:], "8"),
            ("{10 | atMost(4)}", [:], "4"),
            ("{2 | atMost(4)}", [:], "2"),
            // Recently fixed: huge doubles must not trap when converted back.
            ("{big | plus(1)}", ["big": 1e19], "1e+19"),
            ("{big | floor}", ["big": Double.greatestFiniteMagnitude],
             "\(Double.greatestFiniteMagnitude)"),
            ("{big | ceil}", ["big": -Double.greatestFiniteMagnitude],
             "\(-Double.greatestFiniteMagnitude)"),
        ])
    }

    func testUnknownFilterThrowsWithSuggestion() throws {
        let template = try PlumeTemplate("{title | upcas}")
        XCTAssertThrowsError(try template.render(["title": "x"])) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Unsupported Plume filter: upcas"))
            XCTAssertTrue(message.contains("Did you mean upcase?"))
        }
    }
}
