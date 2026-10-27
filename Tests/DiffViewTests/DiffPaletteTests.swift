import SeamCore
import Testing

@testable import DiffView

@Suite(.timeLimit(.minutes(1))) struct DiffPaletteTests {
    @Test(arguments: DiffPalette.all.map(\.name))
    func textMeetsWCAGAAOnEveryBackground(name: String) throws {
        let palette = try #require(DiffPalette.all.first { $0.name == name }?.palette)
        let pairs: [(String, RGB, RGB)] = [
            ("text on context", palette.text, palette.background),
            ("text on added", palette.text, palette.addedBackground),
            ("text on removed", palette.text, palette.removedBackground),
            ("marker on added", palette.addedMarker, palette.addedBackground),
            ("marker on removed", palette.removedMarker, palette.removedBackground),
            ("text on added word", palette.text, palette.addedWord),
            ("text on removed word", palette.text, palette.removedWord),
            ("number on context", palette.gutterText, palette.background),
            ("number on added gutter", palette.gutterText, palette.addedGutter),
            ("number on removed gutter", palette.gutterText, palette.removedGutter),
            ("hunk header", palette.hunkText, palette.hunkBackground),
            ("file header", palette.text, palette.headerBackground),
            ("added count", palette.addedMarker, palette.headerBackground),
            ("removed count", palette.removedMarker, palette.headerBackground),
        ]
        for token in SyntaxToken.allCases {
            guard let color = palette.color(for: token) else { continue }
            for (index, background) in palette.textBackgrounds.enumerated() {
                let ratio = color.contrast(with: background)
                #expect(ratio >= 4.5, "\(name): \(token) on background \(index) is \(ratio)")
            }
        }
        for (label, foreground, background) in pairs {
            let ratio = foreground.contrast(with: background)
            #expect(ratio >= 4.5, "\(name): \(label) is \(ratio)")
        }
    }

    /// Thread rows and the composer sit on the amber wash; the lines a new thread goes on have
    /// their gutter washed more strongly, under line numbers drawn in the text colour.
    @Test(arguments: DiffPalette.all.map(\.name))
    func textMeetsWCAGAAOnTheThreadsAmber(name: String) throws {
        let palette = try #require(DiffPalette.all.first { $0.name == name }?.palette)
        // `systemYellow` in sRGB. Resolving the shared colour here shifts how it composites by
        // a level in snapshot tests running alongside.
        let amber = name.hasPrefix("dark") ? RGB(0xFFD600) : RGB(0xFFCC00)
        func blend(_ alpha: Double, over under: RGB) -> RGB {
            var mixed = under
            mixed.red = amber.red * alpha + under.red * (1 - alpha)
            mixed.green = amber.green * alpha + under.green * (1 - alpha)
            mixed.blue = amber.blue * alpha + under.blue * (1 - alpha)
            return mixed
        }
        let wash = blend(ThreadColor.washAlpha, over: palette.background)
        var pairs: [(String, RGB, RGB)] = [
            ("text on thread row", palette.text, wash),
            ("resolved thread row", palette.gutterText, wash),
        ]
        for (label, gutter) in [
            ("context", palette.background), ("added", palette.addedGutter),
            ("removed", palette.removedGutter),
        ] {
            pairs.append(
                (
                    "number on \(label) target", palette.text,
                    blend(palette.targetAlpha, over: gutter)
                ))
        }
        for (label, foreground, background) in pairs {
            let ratio = foreground.contrast(with: background)
            #expect(ratio >= 4.5, "\(name): \(label) is \(ratio)")
        }
    }

    @Test func contrastMatchesTheWCAGReferenceValues() {
        #expect(abs(RGB(0x000000).contrast(with: RGB(0xFFFFFF)) - 21) < 0.01)
        #expect(abs(RGB(0x777777).contrast(with: RGB(0xFFFFFF)) - 4.48) < 0.01)
    }
}
