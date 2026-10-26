import AppKit

extension AppSettings {
    /// Empty name means SF Mono, the system's monospaced font.
    var font: NSFont {
        let size = CGFloat(min(max(fontSize, 8), 32))
        return NSFont(name: fontName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
