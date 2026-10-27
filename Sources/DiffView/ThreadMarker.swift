import AppKit
import DiffModel
import SeamCore

/// Review threads' colour wherever they show: posted, being written, and the lines `c` would
/// comment on (SPEC §7.7); GitHub's threads in its blue (§7.9).
public enum ThreadColor {
    public static let accent = NSColor.systemYellow
    /// Behind a thread's row and the composer, light enough for text on either appearance.
    public static let wash = accent.withAlphaComponent(washAlpha)
    static let washAlpha = 0.14
    /// A thread's row in the diff, stronger than the card's so it's seen while scrolling.
    static let rowWashAlpha = 0.2
    /// Primer's accent, as github.com draws links and its own highlights.
    public static let gitHubAccent = primerBlue(alpha: 1)
    public static let gitHubWash = primerBlue(alpha: washAlpha)

    private static func primerBlue(alpha: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x44 / 255, green: 0x93 / 255, blue: 0xF8 / 255, alpha: alpha)
                : NSColor(srgbRed: 0x09 / 255, green: 0x69 / 255, blue: 0xDA / 255, alpha: alpha)
        }
    }

    /// A note's grey, for something to know that asks no answer.
    public static let noteAccent = NSColor.systemGray
    public static let noteWash = noteAccent.withAlphaComponent(washAlpha)

    public static func accent(_ source: ThreadSource, note: Bool = false) -> NSColor {
        note ? noteAccent : source == .gitHub ? gitHubAccent : accent
    }

    public static func wash(_ source: ThreadSource, note: Bool = false) -> NSColor {
        note ? noteWash : source == .gitHub ? gitHubWash : wash
    }

    static func rowWash(_ source: ThreadSource, note: Bool) -> NSColor {
        note
            ? noteAccent.withAlphaComponent(rowWashAlpha)
            : source == .gitHub
                ? primerBlue(alpha: rowWashAlpha) : accent.withAlphaComponent(rowWashAlpha)
    }
}
