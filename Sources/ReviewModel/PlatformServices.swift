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
    /// Takes posted notifications out of Notification Center, by id.
    func removeNotifications(_ ids: [String])
    /// The ids of the notifications Notification Center still shows.
    func deliveredNotificationIDs() async -> Set<String>
    /// The Dock icon's badge; none at zero.
    func setBadge(_ count: Int)
    /// The `seam` command shipped with the app, for the agent prompt; nil without one.
    var bundledCommand: URL? { get }
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
    public func removeNotifications(_ ids: [String]) {}
    public func deliveredNotificationIDs() async -> Set<String> { [] }
    public func setBadge(_ count: Int) {}
    public var bundledCommand: URL? { nil }
}

/// The Dock icon's badge (SPEC §7.10): what awaits the reader, summed over the open repos.
@MainActor
public final class DockBadge {
    private var counts: [String: Int] = [:]
    private var shown = 0

    public init() {}

    /// A repo's count, by its main worktree; zero when its window closes.
    func set(_ count: Int, for repo: String, on platform: any PlatformServices) {
        counts[repo] = count == 0 ? nil : count
        let total = counts.values.reduce(0, +)
        guard total != shown else { return }
        shown = total
        platform.setBadge(total)
    }
}
