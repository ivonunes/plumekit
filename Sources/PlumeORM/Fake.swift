import _Concurrency

// Value helpers for factories and seeders: unique-ish random values, so creating many
// rows doesn't collide on unique columns. Byte-wise and OS-RNG based (WASI random_get in
// the guest), so it links under Embedded Swift like the rest of the ORM.
//
//     static let factory = Factory { User(email: Fake.email(), name: Fake.words(2)) }
//     let user = try await User.factory.create(in: db) { $0.email = Fake.email() }
public enum Fake {
    /// A random integer in `range` (default `1...1_000_000`).
    public static func int(in range: ClosedRange<Int> = 1...1_000_000) -> Int {
        var rng = SystemRandomNumberGenerator()
        return Int.random(in: range, using: &rng)
    }

    /// A random lowercase-alphanumeric string of `length` characters.
    public static func string(length: Int = 12) -> String {
        let alphabet: [UInt8] = Array("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
        var rng = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        for _ in 0..<length {
            bytes.append(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A random hex string of `byteCount` bytes (two hex chars each).
    public static func hex(_ byteCount: Int = 16) -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var rng = SystemRandomNumberGenerator()
        var out: [UInt8] = []
        out.reserveCapacity(byteCount * 2)
        for _ in 0..<byteCount {
            let b = UInt8.random(in: UInt8.min...UInt8.max, using: &rng)
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// A unique-ish email like `user-a1b2c3d4@example.com`.
    public static func email() -> String { "user-" + hex(4) + "@example.com" }

    /// A random boolean.
    public static func bool() -> Bool {
        var rng = SystemRandomNumberGenerator()
        return Bool.random(using: &rng)
    }

    /// `count` random lowercase words, space-joined (e.g. `"qmzk fpld"`).
    public static func words(_ count: Int = 3) -> String {
        var out: [UInt8] = []
        for i in 0..<count {
            if i > 0 { out.append(0x20) }   // space
            out.append(contentsOf: Array(string(length: 5).utf8))
        }
        return String(decoding: out, as: UTF8.self)
    }
}
