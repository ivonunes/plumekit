// multipart/form-data parsing, entirely byte-wise over the [UInt8] body —
// boundaries, part headers and field names are matched by byte, never via
// `String.split`/`contains` (those fail to link in the
// embedded guest). Works identically on the native server and the Wasm worker.

public struct MultipartPart: Sendable {
    public let name: String
    public let filename: String?      // nil → a plain field; non-nil → a file part
    public let contentType: String?
    public let body: [UInt8]

    public var isFile: Bool { filename != nil }
}

public struct MultipartForm: Sendable {
    public let parts: [MultipartPart]

    /// A plain field's value (first match), UTF-8 decoded.
    public subscript(_ name: String) -> String? {
        for part in parts where part.filename == nil && utf8Equal(part.name, name) {
            return decodeUTF8(part.body)
        }
        return nil
    }

    /// A file part by field name.
    public func file(_ name: String) -> MultipartPart? {
        for part in parts where part.filename != nil && utf8Equal(part.name, name) { return part }
        return nil
    }

    /// Parse `body` using `boundary` (from the Content-Type header). Returns nil if
    /// the delimiter never appears.
    public init?(body: [UInt8], boundary: String) {
        let delimiter = Array(("--" + boundary).utf8)
        guard !delimiter.isEmpty, body.count >= delimiter.count else { return nil }

        var offsets: [Int] = []
        var i = 0
        while i <= body.count - delimiter.count {
            if regionMatches(body, at: i, delimiter) { offsets.append(i); i += delimiter.count }
            else { i += 1 }
        }
        guard offsets.count >= 2 else { return nil }

        var collected: [MultipartPart] = []
        for k in 0..<(offsets.count - 1) {
            let start = offsets[k] + delimiter.count
            let end = offsets[k + 1]
            if let part = MultipartForm.parsePart(body, start, end) { collected.append(part) }
        }
        self.parts = collected
    }

    // A segment is: [CRLF] headers CRLF CRLF content CRLF. If it begins with "--"
    // it is the closing delimiter — skip it.
    private static func parsePart(_ body: [UInt8], _ rawStart: Int, _ rawEnd: Int) -> MultipartPart? {
        var start = rawStart
        if start + 1 < rawEnd, body[start] == 0x2D, body[start + 1] == 0x2D { return nil }
        // leading CRLF after the boundary line
        if start + 1 < rawEnd, body[start] == 0x0D, body[start + 1] == 0x0A { start += 2 }

        // headers end at CRLF CRLF
        guard let headerEnd = findCRLFCRLF(body, start, rawEnd) else { return nil }
        let headerBytes = Array(body[start..<headerEnd])
        var contentStart = headerEnd + 4
        var contentEnd = rawEnd
        // strip the trailing CRLF that precedes the next delimiter
        if contentEnd >= 2, body[contentEnd - 2] == 0x0D, body[contentEnd - 1] == 0x0A { contentEnd -= 2 }
        if contentStart > contentEnd { contentStart = contentEnd }

        var name: String?
        var filename: String?
        var contentType: String?
        for line in splitCRLFLines(headerBytes) {
            if let disp = headerValue(line, "content-disposition") {
                name = quotedAttribute(Array(disp.utf8), "name")
                filename = quotedAttribute(Array(disp.utf8), "filename")
            } else if let type = headerValue(line, "content-type") {
                contentType = type
            }
        }
        guard let fieldName = name else { return nil }
        return MultipartPart(
            name: fieldName, filename: filename, contentType: contentType,
            body: Array(body[contentStart..<contentEnd]))
    }
}

extension Request {
    /// The multipart boundary from the Content-Type header, if this is multipart.
    public var multipartBoundary: String? {
        guard let type = headers.first("content-type") else { return nil }
        guard bytesContain(Array(type.utf8), Array("multipart/form-data".utf8)) else { return nil }
        return quotedAttribute(Array(type.utf8), "boundary")
    }

    /// Parse the body as multipart/form-data, or nil if it isn't.
    public func multipart() -> MultipartForm? {
        guard let boundary = multipartBoundary else { return nil }
        return MultipartForm(body: body, boundary: boundary)
    }
}

/// A reference to a file part already streamed to the blob store — the handler
/// receives this, not the bytes (and never makes a direct platform/R2 call).
public struct UploadedFile: Sendable {
    public let field: String
    public let filename: String
    public let contentType: String?
    public let key: String
    public let size: Int
}

extension MultipartForm {
    /// Upload file parts to the StorageDriver and return references; plain fields
    /// come back as parameters. Platform-neutral — works on filesystem/R2/S3 alike.
    public func upload(
        to storage: Storage, keyPrefix: String = "uploads/"
    ) async throws -> (fields: FormParams, files: [UploadedFile]) {
        var fieldPairs: [UInt8] = []   // build a urlencoded string for FormParams
        var files: [UploadedFile] = []
        var first = true
        for part in parts {
            if let filename = part.filename {
                let key = keyPrefix + part.name + "/" + filename
                try await storage.put(key, part.body)
                files.append(UploadedFile(field: part.name, filename: filename,
                                          contentType: part.contentType, key: key, size: part.body.count))
            } else {
                if !first { fieldPairs.append(0x26) }   // &
                first = false
                fieldPairs.append(contentsOf: percentEncode(part.name))
                fieldPairs.append(0x3D)                 // =
                fieldPairs.append(contentsOf: percentEncode(part.body))
            }
        }
        return (FormParams(decodeUTF8(fieldPairs)), files)
    }
}

// Minimal percent-encoding (so multipart field values round-trip through FormParams).
private func percentEncode(_ string: String) -> [UInt8] { percentEncode(Array(string.utf8)) }
private func percentEncode(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    let hex = Array("0123456789ABCDEF".utf8)
    for b in bytes {
        let unreserved = (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || (b >= 0x30 && b <= 0x39) || b == 0x2D || b == 0x2E || b == 0x5F || b == 0x7E
        if unreserved { out.append(b) }
        else { out.append(0x25); out.append(hex[Int(b >> 4)]); out.append(hex[Int(b & 0xF)]) }
    }
    return out
}

// MARK: - Byte helpers

func regionMatches(_ body: [UInt8], at offset: Int, _ pattern: [UInt8]) -> Bool {
    if offset + pattern.count > body.count { return false }
    var j = 0
    while j < pattern.count { if body[offset + j] != pattern[j] { return false }; j += 1 }
    return true
}

private func findCRLFCRLF(_ body: [UInt8], _ start: Int, _ end: Int) -> Int? {
    var i = start
    while i + 3 < end {
        if body[i] == 0x0D, body[i + 1] == 0x0A, body[i + 2] == 0x0D, body[i + 3] == 0x0A { return i }
        i += 1
    }
    return nil
}

private func splitCRLFLines(_ bytes: [UInt8]) -> [[UInt8]] {
    var lines: [[UInt8]] = []
    var current: [UInt8] = []
    var i = 0
    while i < bytes.count {
        if i + 1 < bytes.count, bytes[i] == 0x0D, bytes[i + 1] == 0x0A {
            lines.append(current); current = []; i += 2
        } else {
            current.append(bytes[i]); i += 1
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

// If `line` starts with "<name>:" (ASCII case-insensitive), return its trimmed value.
private func headerValue(_ line: [UInt8], _ name: String) -> String? {
    let prefix = Array(name.utf8)
    if line.count <= prefix.count { return nil }
    var j = 0
    while j < prefix.count {
        if asciiLowerByte(line[j]) != asciiLowerByte(prefix[j]) { return nil }
        j += 1
    }
    if line[prefix.count] != 0x3A { return nil }  // ':'
    var v = prefix.count + 1
    while v < line.count, line[v] == 0x20 { v += 1 }  // skip spaces
    return decodeUTF8(Array(line[v...]))
}

// Extract a `name=value` attribute (value either "quoted" or bare until `;`/space).
func quotedAttribute(_ source: [UInt8], _ attribute: String) -> String? {
    let needle = Array((attribute + "=").utf8)
    var i = 0
    while i <= source.count - needle.count {
        // Anchor on a boundary so `name=` can't match inside `filename=` (a reordered
        // Content-Disposition would otherwise return the filename as the field name).
        let boundary = i == 0 || source[i - 1] == 0x20 || source[i - 1] == 0x3B || source[i - 1] == 0x09
        if boundary, regionMatches(source, at: i, needle) {
            var j = i + needle.count
            var value: [UInt8] = []
            if j < source.count, source[j] == 0x22 {       // quoted
                j += 1
                while j < source.count, source[j] != 0x22 { value.append(source[j]); j += 1 }
            } else {                                        // bare
                while j < source.count, source[j] != 0x3B, source[j] != 0x20 { value.append(source[j]); j += 1 }
            }
            return decodeUTF8(value)
        }
        i += 1
    }
    return nil
}

private func asciiLowerByte(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c &+ 32 : c }
