import Foundation

/// Map an arbitrary KV/Storage key to a collision-free, filesystem-safe filename by
/// percent-encoding every byte outside `[A-Za-z0-9_-]`. Distinct keys always map to
/// distinct names (the old "collapse to `_`" scheme silently merged e.g. `a/b` and
/// `a+b`), and no name can be `.`/`..` or contain a path separator.
func safeStoreFilename(_ key: String) -> String {
    let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
    var out: [UInt8] = []
    for byte in key.utf8 {
        let safe = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
        if safe {
            out.append(byte)
        } else {
            out.append(0x25)                    // '%'
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0x0F)])
        }
    }
    return out.isEmpty ? "%00" : String(decoding: out, as: UTF8.self)
}
