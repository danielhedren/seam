import Foundation

/// What the models ask of the desktop around them (ADR 0007): the pasteboard, the browser,
/// the file manager and notifications. The app passes `MacPlatform`; tests record what was
/// asked.
@MainActor
public protocol PlatformServices: Sendable {
    func copy(_ text: String)
    func open(_ url: URL)
    func reveal(_ file: URL)
    func notify(_ notification: SeamNotification)
}

/// One notification (SPEC §7.10). Clicking it opens `url`, a `seam://open` link.
public struct SeamNotification: Equatable, Sendable {
    /// Posting another with the same id replaces it.
    public var id: String
    /// Notifications of one worktree stack together.
    public var group: String
    public var title: String
    public var body: String
    public var url: URL?
}

/// For sessions with no desktop to talk to, as in tests that don't look.
public struct NoPlatform: PlatformServices {
    public init() {}
    public func copy(_ text: String) {}
    public func open(_ url: URL) {}
    public func reveal(_ file: URL) {}
    public func notify(_ notification: SeamNotification) {}
}
