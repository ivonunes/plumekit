/// A Foundation-free RFC 4122 UUID value.
///
/// Stored as lowercase canonical text (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)
/// so it can travel through SQL, JSON, and worker wire formats without adding a
/// new binary cell type. `UUID()` generates a version-4 UUID with the standard
/// library's system RNG, which maps to OS randomness natively and WASI randomness
/// in the wasm guest.
public struct UUID: Sendable, Hashable, CustomStringConvertible {
    private let storage: String

    public init() {
        var rng = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        for _ in 0..<16 { bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &rng)) }
        bytes[6] = (bytes[6] & 0x0f) | 0x40   // version 4
        bytes[8] = (bytes[8] & 0x3f) | 0x80   // RFC 4122 variant
        self.storage = UUID.format(bytes)
    }

    /// Build from canonical UUID text. Invalid input yields the all-zero UUID;
    /// use `init?(uuidString:)` when callers need validation.
    public init(_ string: String) {
        self.storage = UUID.canonical(string) ?? UUID.zero.storage
    }

    public init?(uuidString: String) {
        guard let canonical = UUID.canonical(uuidString) else { return nil }
        self.storage = canonical
    }

    private init(canonical: String) {
        self.storage = canonical
    }

    public static let zero = UUID(canonical: "00000000-0000-0000-0000-000000000000")

    public var uuidString: String { storage }
    public var description: String { storage }

    public static func == (lhs: UUID, rhs: UUID) -> Bool {
        Array(lhs.storage.utf8) == Array(rhs.storage.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        for byte in storage.utf8 { hasher.combine(byte) }
    }

    private static func canonical(_ string: String) -> String? {
        let bytes = Array(string.utf8)
        if bytes.count == 36 { return canonicalDashed(bytes) }
        if bytes.count == 32 { return canonicalUndashed(bytes) }
        return nil
    }

    private static func canonicalDashed(_ bytes: [UInt8]) -> String? {
        let dashPositions: [Int] = [8, 13, 18, 23]
        var hex: [UInt8] = []
        for i in 0..<bytes.count {
            if dashPositions.contains(i) {
                if bytes[i] != 0x2d { return nil }
            } else if let lower = lowerHex(bytes[i]) {
                hex.append(lower)
            } else {
                return nil
            }
        }
        return canonicalUndashed(hex)
    }

    private static func canonicalUndashed(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 32 else { return nil }
        var hex: [UInt8] = []
        for byte in bytes {
            guard let lower = lowerHex(byte) else { return nil }
            hex.append(lower)
        }
        var out: [UInt8] = []
        for i in 0..<hex.count {
            if i == 8 || i == 12 || i == 16 || i == 20 { out.append(0x2d) }
            out.append(hex[i])
        }
        return decodeUTF8(out)
    }

    private static func lowerHex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte
        case 0x41...0x46: return byte + 32
        case 0x61...0x66: return byte
        default: return nil
        }
    }

    private static func format(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for i in 0..<bytes.count {
            if i == 4 || i == 6 || i == 8 || i == 10 { out.append(0x2d) }
            let byte = bytes[i]
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return decodeUTF8(out)
    }
}
