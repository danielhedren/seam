/// Display columns for raw line text: tabs advance to the next stop, and a CRLF line's CR is
/// dropped, or shown as one visible marker when asked. Everything that maps raw offsets to
/// columns goes through here.
package enum TabStops {
    static func expand(_ text: String, width: Int, showsReturns: Bool = false) -> String {
        guard text.contains("\t") || text.hasSuffix("\r") else { return text }
        // The CR is a line's last character, so dropping it moves no column before it.
        let text = showsReturns || !text.hasSuffix("\r") ? text : String(text.dropLast())
        var result = ""
        var column = 0
        for character in text {
            switch character {
            case "\t":
                let spaces = width - column % width
                result += String(repeating: " ", count: spaces)
                column += spaces
            // CRLF files: the CR is drawn as a visible marker rather than moving the caret.
            case "\r":
                result += "␍"
                column += 1
            default:
                result.append(character)
                column += 1
            }
        }
        return result
    }

    /// The display column of each raw character, plus one past the end.
    package static func columns(_ raw: String, width: Int) -> [Int] {
        var columns: [Int] = []
        var column = 0
        for character in raw {
            columns.append(column)
            column += character == "\t" ? width - column % width : 1
        }
        columns.append(column)
        return columns
    }
}
