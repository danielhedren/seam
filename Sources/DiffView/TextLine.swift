import AppKit
import CoreText
import SeamCore

/// Core Text lines for everything the diff draws. Plain runs take the context's fill colour, so a
/// cached line redraws in any colour; syntax runs carry their own.
@MainActor
enum TextLine {
    static func make(_ text: String, font: NSFont) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
    }

    /// Unhighlighted runs take the context's fill colour; spans carry their own.
    static func make(
        _ text: String, font: NSFont, syntax: [SyntaxSpan], palette: DiffPalette
    ) -> CTLine {
        let string = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
        let length = text.count
        var utf16Offsets: [Int] = []
        utf16Offsets.reserveCapacity(length + 1)
        var offset = 0
        for character in text {
            utf16Offsets.append(offset)
            offset += character.utf16.count
        }
        utf16Offsets.append(offset)
        for span in syntax {
            guard let color = palette.color(for: span.token), span.range.lowerBound < length
            else { continue }
            let lower = utf16Offsets[span.range.lowerBound]
            let upper = utf16Offsets[min(span.range.upperBound, length)]
            let range = NSRange(location: lower, length: upper - lower)
            string.removeAttribute(
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String),
                range: range)
            string.addAttribute(
                NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                value: color.nsColor.cgColor, range: range)
        }
        return CTLineCreateWithAttributedString(string)
    }
}
