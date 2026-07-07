//
//  PlumeStreamEnvelopeTests.swift
//  PlumeTests — fragment + stream envelope
//
//  The stream envelope is Plume's documented wire format. These tests pin the
//  exact bytes for every action, prove a fragment renders context-independently
//  (data in, bytes out, no request/host), and confirm targets are escaped.
//

import Testing

import PlumeRuntime

@Suite struct PlumeStreamEnvelopeTests {
    func string(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    @Test func fragmentRendersStandalone() {
        // No ambient request, no host — just a render closure producing bytes.
        let bytes = Plume.fragment { out in
            out.literal("<li>")
            out.text("A & B")
            out.literal("</li>")
        }
        #expect(string(bytes) == "<li>A &amp; B</li>")
    }

    @Test func appendWrapsFragmentInTemplate() {
        var envelope = StreamEnvelope()
        envelope.add(.append, target: "messages") { out in out.literal("<li>hi</li>") }
        #expect(
            string(envelope.bytes)
                == #"<plume-stream action="append" target="messages"><template><li>hi</li></template></plume-stream>"#)
    }

    @Test func removeCarriesNoFragment() {
        var envelope = StreamEnvelope()
        envelope.remove(target: "flash")
        #expect(
            string(envelope.bytes)
                == #"<plume-stream action="remove" target="flash"></plume-stream>"#)
    }

    @Test func everyActionEncodesItsWireName() {
        let actions: [(StreamAction, String)] = [
            (.append, "append"), (.prepend, "prepend"), (.replace, "replace"),
            (.update, "update"), (.remove, "remove"), (.before, "before"),
            (.after, "after"), (.morph, "morph"),
        ]
        for (action, name) in actions {
            var envelope = StreamEnvelope()
            envelope.add(action, target: "t", fragment: Array("X".utf8))
            #expect(string(envelope.bytes).contains(#"action="\#(name)""#))
        }
    }

    @Test func targetIsAttributeEscaped() {
        var envelope = StreamEnvelope()
        envelope.add(.replace, target: #"a"<b>&"#) { out in out.literal("x") }
        #expect(string(envelope.bytes).contains(#"target="a&quot;&lt;b&gt;&amp;""#))
    }

    @Test func operationsConcatenate() {
        var envelope = StreamEnvelope()
        envelope.add(.append, target: "list") { out in out.literal("<li>1</li>") }
        envelope.remove(target: "old")
        let expected =
            #"<plume-stream action="append" target="list"><template><li>1</li></template></plume-stream>"#
            + #"<plume-stream action="remove" target="old"></plume-stream>"#
        #expect(string(envelope.bytes) == expected)
    }

    @Test func morphReplacesInPlaceOnTheWire() {
        var envelope = StreamEnvelope()
        envelope.add(.morph, target: "card") { out in out.literal("<div>new</div>") }
        #expect(
            string(envelope.bytes)
                == #"<plume-stream action="morph" target="card"><template><div>new</div></template></plume-stream>"#)
    }
}
