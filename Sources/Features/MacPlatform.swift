import AppKit

public struct MacPlatform: PlatformServices {
    public init() {}

    public func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func open(_ url: URL) { NSWorkspace.shared.open(url) }

    public func reveal(_ file: URL) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
}
