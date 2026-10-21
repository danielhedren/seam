import AppKit

/// An sRGB colour as plain numbers, so contrast is checked by a unit test (SPEC §9).
struct RGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    /// WCAG 2 relative luminance.
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    func contrast(with other: RGB) -> Double {
        let (light, dark) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (light + 0.05) / (dark + 0.05)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

/// Diff colours for one appearance. Defined in code rather than an asset catalog because
/// `swift build` does not compile asset catalogs, and the contrast test reads these values.
struct DiffPalette: Equatable, Sendable {
    var background: RGB
    var text: RGB
    var gutterText: RGB
    var addedBackground: RGB
    var removedBackground: RGB
    var addedGutter: RGB
    var removedGutter: RGB
    var addedMarker: RGB
    var removedMarker: RGB
    var hunkBackground: RGB
    var hunkText: RGB
    var headerBackground: RGB
    var emptySide: RGB
    var separator: RGB

    static let light = DiffPalette(
        background: RGB(0xFFFFFF), text: RGB(0x1F2328), gutterText: RGB(0x57606A),
        addedBackground: RGB(0xE6FFEC), removedBackground: RGB(0xFFEBE9),
        addedGutter: RGB(0xCCFFD8), removedGutter: RGB(0xFFD7D5),
        addedMarker: RGB(0x116329), removedMarker: RGB(0xA40E26),
        hunkBackground: RGB(0xDDF4FF), hunkText: RGB(0x4B535C),
        headerBackground: RGB(0xF6F8FA), emptySide: RGB(0xF3F4F6), separator: RGB(0xD0D7DE))

    static let dark = DiffPalette(
        background: RGB(0x1E1E1E), text: RGB(0xE6EDF3), gutterText: RGB(0xADB5BE),
        addedBackground: RGB(0x1D3325), removedBackground: RGB(0x3B2228),
        addedGutter: RGB(0x1F4229), removedGutter: RGB(0x4A2329),
        addedMarker: RGB(0x56D364), removedMarker: RGB(0xFF7B72),
        hunkBackground: RGB(0x1C2B3D), hunkText: RGB(0xA8B1BB),
        headerBackground: RGB(0x262626), emptySide: RGB(0x242424), separator: RGB(0x3D3D3D))

    static let lightHighContrast = DiffPalette(
        background: RGB(0xFFFFFF), text: RGB(0x000000), gutterText: RGB(0x3B3B3B),
        addedBackground: RGB(0xD2F8DA), removedBackground: RGB(0xFFDCDC),
        addedGutter: RGB(0xB4F0C2), removedGutter: RGB(0xFFC4C4),
        addedMarker: RGB(0x00501A), removedMarker: RGB(0x7A0010),
        hunkBackground: RGB(0xCDEBFF), hunkText: RGB(0x1A1A1A),
        headerBackground: RGB(0xEDEDED), emptySide: RGB(0xE4E4E4), separator: RGB(0x6E6E6E))

    static let darkHighContrast = DiffPalette(
        background: RGB(0x000000), text: RGB(0xFFFFFF), gutterText: RGB(0xC8C8C8),
        addedBackground: RGB(0x0E3A1C), removedBackground: RGB(0x4A1219),
        addedGutter: RGB(0x135226), removedGutter: RGB(0x651A23),
        addedMarker: RGB(0x7EF08E), removedMarker: RGB(0xFFA19B),
        hunkBackground: RGB(0x0F2A45), hunkText: RGB(0xE0E0E0),
        headerBackground: RGB(0x1A1A1A), emptySide: RGB(0x141414), separator: RGB(0x9A9A9A))

    static let all: [(name: String, palette: DiffPalette)] = [
        ("light", .light), ("dark", .dark), ("light high contrast", .lightHighContrast),
        ("dark high contrast", .darkHighContrast),
    ]

    /// High-contrast appearances can't be constructed or matched by name, so Increase Contrast
    /// comes from the workspace setting rather than the appearance.
    static func current(for appearance: NSAppearance, increaseContrast: Bool) -> DiffPalette {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return switch (dark, increaseContrast) {
        case (false, false): .light
        case (true, false): .dark
        case (false, true): .lightHighContrast
        case (true, true): .darkHighContrast
        }
    }
}
