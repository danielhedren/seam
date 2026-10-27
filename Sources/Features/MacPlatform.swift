import AppKit
import ReviewModel
import UserNotifications

public struct MacPlatform: PlatformServices {
    public init() {}

    public func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func open(_ url: URL) { NSWorkspace.shared.open(url) }

    public func reveal(_ file: URL) { NSWorkspace.shared.activateFileViewerSelecting([file]) }

    public var bundledCommand: URL? { Bundle.main.url(forResource: "seam", withExtension: nil) }

    /// An installed app by bundle id, for editors' presets and their bundled tools.
    @Sendable public nonisolated static func locateApp(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Clicked, the notification's `seam://` URL comes back through `SeamAppDelegate`.
    public func notify(_ notification: SeamNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = notification.group
        if let url = notification.url { content.userInfo = ["url": url.absoluteString] }
        let request = UNNotificationRequest(
            identifier: notification.id, content: content, trigger: nil)
        Task {
            guard await Self.mayNotify() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Asks the first time; while that question is unanswered the system can refuse, so it's
    /// asked again next time rather than taken as a no.
    static func mayNotify() async -> Bool {
        guard isApp else { return false }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default: return false
        }
    }

    /// Whether macOS has notifications off for Seam, which only System Settings can undo.
    static func notificationsDenied() async -> Bool {
        guard isApp else { return false }
        return await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus == .denied
    }

    /// The notification center throws outside an app bundle, as in tests.
    private static var isApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }
}
