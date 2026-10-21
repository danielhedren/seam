/// The one way Seam splits file text into lines. Splits on the newline byte: `"\r\n"` is a single
/// Character, so a Character split would see a CRLF file as one line. Lines keep their `\r`, like
/// a patch's lines do, and a final newline adds no empty last line.
public enum TextLines {
    public static func split(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { Substring($0) }
        if text.utf8.last == UInt8(ascii: "\n") { lines.removeLast() }
        return lines
    }
}
