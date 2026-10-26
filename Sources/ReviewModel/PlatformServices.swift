import Foundation

/// What the models ask of the desktop around them (ADR 0007): the pasteboard, the browser and
/// the file manager. The app passes `MacPlatform`; tests record what was asked.
@MainActor
public protocol PlatformServices: Sendable {
    func copy(_ text: String)
    func open(_ url: URL)
    func reveal(_ file: URL)
}

/// For sessions with no desktop to talk to, as in tests that don't look.
public struct NoPlatform: PlatformServices {
    public init() {}
    public func copy(_ text: String) {}
    public func open(_ url: URL) {}
    public func reveal(_ file: URL) {}
}
