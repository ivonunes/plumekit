// Runtime proof that native Swift `String` operations link AND behave correctly in the
// Embedded-Wasm guest (with libswiftUnicodeDataTables.a linked). Prints one PASS/FAIL
// line per case and a final ALL-PASS / FAILURES:n; exits non-zero on any failure so the
// gate script can trust the exit code as well as the output.
#if canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ s: String) {
    let bytes = Array((s + "\n").utf8)
    bytes.withUnsafeBufferPointer { _ = write(1, $0.baseAddress, $0.count) }
}

// Build strings at runtime so nothing is constant-folded into a compile-time literal
// (which would make `==` a compile-time bool and never exercise the linked machinery).
func rt(_ s: String) -> String { var c = ""; for ch in s { c.append(ch) }; return c }

func main() -> Int32 {
    var failures = 0
    func expect(_ label: String, _ got: Bool, _ want: Bool) {
        let ok = (got == want)
        emit("\(ok ? "PASS" : "FAIL") \(label): got=\(got) want=\(want)")
        if !ok { failures += 1 }
    }

    // ASCII / identical-bytes fast paths — must equal real Swift exactly.
    expect("ascii-equal", rt("abc") == (rt("ab") + rt("c")), true)
    expect("ascii-not-equal", rt("abc") != rt("abd"), true)
    expect("empty-equal", rt("") == rt(""), true)
    expect("nonascii-same-bytes", rt("Pastéis") == rt("Pastéis"), true)

    // Byte-different non-ASCII compares UNEQUAL — these are distinct words, not
    // canonical-equivalent forms, so native Swift agrees.
    expect("nonascii-diff-bytes", rt("Pastéis") == rt("Pasteis"), false)

    // Canonical equivalence: precomposed "é" (U+00E9) vs decomposed "e"+U+0301. With the
    // Unicode tables linked this is TRUE (full native semantics) — why linking the tables
    // is strictly better than byte-only stubs.
    expect("canonical-equivalent", rt("caf\u{00E9}") == rt("cafe\u{0301}"), true)

    // Prefix / suffix / case-mapping / Dictionary all rely on the same tables.
    expect("has-prefix", rt("abcdef").hasPrefix(rt("abc")), true)
    expect("has-suffix", rt("abcdef").hasSuffix(rt("def")), true)
    expect("lowercased-ascii", rt("ABC").lowercased() == rt("abc"), true)
    expect("lowercased-accent", rt("É").lowercased() == rt("é"), true)   // real case mapping
    var dict: [String: Int] = [:]
    dict[rt("Pastéis")] = 42
    expect("dict-string-key", (dict[rt("Pastéis")] ?? -1) == 42, true)

    // split(separator:) uses Character/grapheme breaking — also table-backed.
    expect("split-count", rt("a,b,c").split(separator: ",").count == 3, true)
    expect("split-piece", String(rt("a,b,c").split(separator: ",")[1]) == rt("b"), true)

    emit(failures == 0 ? "ALL-PASS" : "FAILURES:\(failures)")
    return failures == 0 ? 0 : 1
}

exit(main())
