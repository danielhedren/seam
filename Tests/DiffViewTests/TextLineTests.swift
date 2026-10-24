import AppKit
import CoreText
import SeamCore
import Testing

@testable import DiffView

@MainActor @Suite(.timeLimit(.minutes(1))) struct TextLineTests {
    /// Drawing a coloured run sets the context's fill, so a plain run after it that took the
    /// context's colour came out in the span's colour.
    @Test func textAfterASpanKeepsThePlainColour() throws {
        let palette = DiffPalette.dark
        let line = TextLine.make(
            "status.ShouldBe(body);", font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            syntax: [SyntaxSpan(range: 7..<15, token: .function)], palette: palette,
            plain: palette.text)
        let runs = try #require(CTLineGetGlyphRuns(line) as? [CTRun])
        let colours = runs.map { run in
            (CTRunGetAttributes(run) as NSDictionary)[kCTForegroundColorAttributeName as String]
                as AnyObject?
        }
        let plain = palette.text.nsColor.cgColor
        let function = try #require(palette.color(for: .function)).nsColor.cgColor
        let expected = [plain, function, plain]
        #expect(colours.count == expected.count)
        for (colour, wanted) in zip(colours, expected) {
            #expect(colour.map { CFEqual($0, wanted) } == true)
        }
    }
}
