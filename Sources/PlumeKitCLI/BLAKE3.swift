import Foundation

enum BLAKE3 {
    private static let blockLength = 64
    private static let chunkLength = 1024
    private static let outputLength = 32

    private static let chunkStart: UInt32 = 1 << 0
    private static let chunkEnd: UInt32 = 1 << 1
    private static let parent: UInt32 = 1 << 2
    private static let root: UInt32 = 1 << 3

    private static let iv: [UInt32] = [
        0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
        0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19
    ]

    private static let messagePermutation = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]

    static func hash(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        let chunkCount = max(1, (bytes.count + chunkLength - 1) / chunkLength)
        var stack: [[UInt32]] = []
        var currentOutput: Output?

        for chunkIndex in 0..<chunkCount {
            let start = chunkIndex * chunkLength
            let end = min(start + chunkLength, bytes.count)
            let chunk = bytes[start..<end]
            let output = chunkOutput(chunk, chunkCounter: UInt64(chunkIndex))
            if chunkIndex == chunkCount - 1 {
                currentOutput = output
            } else {
                addChunkChainingValue(output.chainingValue(), totalChunks: UInt64(chunkIndex + 1), stack: &stack)
            }
        }

        var output = currentOutput ?? chunkOutput([], chunkCounter: 0)
        while let left = stack.popLast() {
            output = parentOutput(left: left, right: output.chainingValue())
        }
        return output.rootBytes()
    }

    static func hex(_ data: Data) -> String {
        hash(data).map { String(format: "%02x", $0) }.joined()
    }

    private static func addChunkChainingValue(_ cv: [UInt32], totalChunks: UInt64, stack: inout [[UInt32]]) {
        var current = cv
        var chunks = totalChunks
        while chunks & 1 == 0 {
            current = parentOutput(left: stack.removeLast(), right: current).chainingValue()
            chunks >>= 1
        }
        stack.append(current)
    }

    private static func chunkOutput(_ chunk: ArraySlice<UInt8>, chunkCounter: UInt64) -> Output {
        var cv = iv
        var offset = chunk.startIndex
        var remaining = chunk.count
        var blocksCompressed = 0

        while remaining > blockLength {
            let blockEnd = chunk.index(offset, offsetBy: blockLength)
            let flags = blocksCompressed == 0 ? chunkStart : 0
            cv = Array(compress(
                chainingValue: cv,
                blockWords: words(from: chunk[offset..<blockEnd]),
                counter: chunkCounter,
                blockLength: UInt32(blockLength),
                flags: flags
            ).prefix(8))
            blocksCompressed += 1
            offset = blockEnd
            remaining -= blockLength
        }

        let finalFlags = chunkEnd | (blocksCompressed == 0 ? chunkStart : 0)
        return Output(
            inputChainingValue: cv,
            blockWords: words(from: chunk[offset..<chunk.endIndex]),
            counter: chunkCounter,
            blockLength: UInt32(remaining),
            flags: finalFlags
        )
    }

    private static func parentOutput(left: [UInt32], right: [UInt32]) -> Output {
        Output(
            inputChainingValue: iv,
            blockWords: left + right,
            counter: 0,
            blockLength: UInt32(blockLength),
            flags: parent
        )
    }

    private static func words(from block: ArraySlice<UInt8>) -> [UInt32] {
        var padded = [UInt8](repeating: 0, count: blockLength)
        for (index, byte) in block.enumerated() {
            padded[index] = byte
        }
        var output: [UInt32] = []
        output.reserveCapacity(16)
        for offset in stride(from: 0, to: blockLength, by: 4) {
            output.append(
                UInt32(padded[offset])
                    | (UInt32(padded[offset + 1]) << 8)
                    | (UInt32(padded[offset + 2]) << 16)
                    | (UInt32(padded[offset + 3]) << 24)
            )
        }
        return output
    }

    private static func compress(
        chainingValue: [UInt32],
        blockWords: [UInt32],
        counter: UInt64,
        blockLength: UInt32,
        flags: UInt32
    ) -> [UInt32] {
        var state = [
            chainingValue[0], chainingValue[1], chainingValue[2], chainingValue[3],
            chainingValue[4], chainingValue[5], chainingValue[6], chainingValue[7],
            iv[0], iv[1], iv[2], iv[3],
            UInt32(truncatingIfNeeded: counter),
            UInt32(truncatingIfNeeded: counter >> 32),
            blockLength,
            flags
        ]
        var message = blockWords

        for _ in 0..<7 {
            round(state: &state, message: message)
            message = permute(message)
        }

        for index in 0..<8 {
            state[index] ^= state[index + 8]
            state[index + 8] ^= chainingValue[index]
        }
        return state
    }

    private static func round(state: inout [UInt32], message: [UInt32]) {
        mix(&state, 0, 4, 8, 12, message[0], message[1])
        mix(&state, 1, 5, 9, 13, message[2], message[3])
        mix(&state, 2, 6, 10, 14, message[4], message[5])
        mix(&state, 3, 7, 11, 15, message[6], message[7])
        mix(&state, 0, 5, 10, 15, message[8], message[9])
        mix(&state, 1, 6, 11, 12, message[10], message[11])
        mix(&state, 2, 7, 8, 13, message[12], message[13])
        mix(&state, 3, 4, 9, 14, message[14], message[15])
    }

    private static func mix(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt32, _ y: UInt32) {
        state[a] = state[a] &+ state[b] &+ x
        state[d] = rotateRight(state[d] ^ state[a], by: 16)
        state[c] = state[c] &+ state[d]
        state[b] = rotateRight(state[b] ^ state[c], by: 12)
        state[a] = state[a] &+ state[b] &+ y
        state[d] = rotateRight(state[d] ^ state[a], by: 8)
        state[c] = state[c] &+ state[d]
        state[b] = rotateRight(state[b] ^ state[c], by: 7)
    }

    private static func permute(_ message: [UInt32]) -> [UInt32] {
        messagePermutation.map { message[$0] }
    }

    private static func rotateRight(_ value: UInt32, by shift: UInt32) -> UInt32 {
        (value >> shift) | (value << (32 - shift))
    }

    private struct Output {
        var inputChainingValue: [UInt32]
        var blockWords: [UInt32]
        var counter: UInt64
        var blockLength: UInt32
        var flags: UInt32

        func chainingValue() -> [UInt32] {
            Array(BLAKE3.compress(
                chainingValue: inputChainingValue,
                blockWords: blockWords,
                counter: counter,
                blockLength: blockLength,
                flags: flags
            ).prefix(8))
        }

        func rootBytes(length: Int = BLAKE3.outputLength) -> Data {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(length)
            var outputCounter: UInt64 = 0
            while bytes.count < length {
                let words = BLAKE3.compress(
                    chainingValue: inputChainingValue,
                    blockWords: blockWords,
                    counter: outputCounter,
                    blockLength: blockLength,
                    flags: flags | BLAKE3.root
                )
                for word in words {
                    bytes.append(UInt8(truncatingIfNeeded: word))
                    bytes.append(UInt8(truncatingIfNeeded: word >> 8))
                    bytes.append(UInt8(truncatingIfNeeded: word >> 16))
                    bytes.append(UInt8(truncatingIfNeeded: word >> 24))
                }
                outputCounter += 1
            }
            return Data(bytes.prefix(length))
        }
    }
}
