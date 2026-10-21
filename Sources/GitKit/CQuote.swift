import Foundation

/// Git's C-style path quoting. With `core.quotepath=off` git still quotes paths containing
/// control characters, `"` or `\`.
enum CQuote {
    /// Parses a quoted string starting at `bytes[start]` (which must be `"`). Returns the decoded
    /// string and the index just past the closing quote.
    static func parse(_ bytes: ArraySlice<UInt8>, from start: Int) -> (String, Int)? {
        guard start < bytes.endIndex, bytes[start] == UInt8(ascii: "\"") else { return nil }
        var out: [UInt8] = []
        var i = start + 1
        while i < bytes.endIndex {
            let byte = bytes[i]
            if byte == UInt8(ascii: "\"") {
                return (String(decoding: out, as: UTF8.self), i + 1)
            }
            guard byte == UInt8(ascii: "\\") else {
                out.append(byte)
                i += 1
                continue
            }
            i += 1
            guard i < bytes.endIndex else { return nil }
            let escaped = bytes[i]
            if let simple = simpleEscapes[escaped] {
                out.append(simple)
                i += 1
            } else if isOctal(escaped), i + 2 < bytes.endIndex, isOctal(bytes[i + 1]),
                isOctal(bytes[i + 2])
            {
                let value =
                    (Int(escaped) - 48) * 64 + (Int(bytes[i + 1]) - 48) * 8
                    + (Int(bytes[i + 2]) - 48)
                guard value <= 255 else { return nil }
                out.append(UInt8(value))
                i += 3
            } else {
                return nil
            }
        }
        return nil
    }

    /// Decodes a whole path field that may or may not be quoted.
    static func unquote(_ field: ArraySlice<UInt8>) -> String? {
        if field.first == UInt8(ascii: "\"") {
            guard let (value, end) = parse(field, from: field.startIndex), end == field.endIndex
            else { return nil }
            return value
        }
        return String(decoding: field, as: UTF8.self)
    }

    private static let simpleEscapes: [UInt8: UInt8] = [
        UInt8(ascii: "a"): 0x07, UInt8(ascii: "b"): 0x08, UInt8(ascii: "f"): 0x0C,
        UInt8(ascii: "n"): 0x0A, UInt8(ascii: "r"): 0x0D, UInt8(ascii: "t"): 0x09,
        UInt8(ascii: "v"): 0x0B, UInt8(ascii: "\\"): 0x5C, UInt8(ascii: "\""): 0x22,
    ]

    private static func isOctal(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "7")
    }
}
