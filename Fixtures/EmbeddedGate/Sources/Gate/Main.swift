#if canImport(WASILibc)
import WASILibc
#endif
import PlumeRuntime

@main
struct Main {
    static func main() {
        var out = HTML()
        postList(
            posts: [
                Post(title: "Hello & <World>", slug: "hello"),
                Post(title: "Second", slug: "second"),
            ],
            into: &out)
        out.literal("\n")

        // A stream envelope, encoded in-guest (Embedded-clean), wrapping a
        // standalone fragment and a remove. This link-tests the stream envelope under wasm.
        var stream = StreamEnvelope()
        stream.add(.append, target: "posts") { fragment in
            fragment.literal("<li>new</li>")
        }
        stream.remove(target: "flash")
        out.append(stream.bytes)

        emit(out.bytes)
    }

    static func emit(_ bytes: [UInt8]) {
        #if canImport(WASILibc)
        bytes.withUnsafeBufferPointer { _ = write(1, $0.baseAddress, $0.count) }
        #else
        FileHandle.standardOutput.write(Data(bytes))
        #endif
    }
}

#if !canImport(WASILibc)
import Foundation
#endif
