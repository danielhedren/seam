/// Display columns for raw line text: tabs advance to the next stop, a CR shows as one visible
/// marker. Everything that maps raw offsets to columns goes through here.
enum TabStops {
    static func expand(_ text: String, width: Int) -> String {
        guard text.contains("\t") || text.hasSuffix("\r") else { return text }
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
    static func columns(_ raw: String, width: Int) -> [Int] {
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
