import AppKit
import CoreSpotlight
import Foundation
import SeamCore
import UniformTypeIdentifiers
import os

/// Recent repositories in Spotlight (SPEC §7.1): typing part of a repo's name there lists it,
/// and picking it opens the repo in Seam.
public protocol RepoIndex: Sendable {
    /// Makes Seam's Spotlight entries exactly these repos.
    func replace(with repositories: [URL]) async
}

/// Indexes nothing, for tests and previews.
public struct NoRepoIndex: RepoIndex {
    public init() {}
    public func replace(with repositories: [URL]) async {}
}

public struct SpotlightRepoIndex: RepoIndex {
    static let domain = "com.danielhedren.seam.repositories"
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")

    public init() {}

    public func replace(with repositories: [URL]) async {
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
            try await index.indexSearchableItems(Self.items(for: repositories))
        } catch {
            logger.error("spotlight: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func items(for repositories: [URL]) -> [CSSearchableItem] {
        repositories.map { url in
            let attributes = CSSearchableItemAttributeSet(contentType: .folder)
            attributes.title = url.lastPathComponent
            attributes.displayName = url.lastPathComponent
            attributes.contentDescription = (url.path as NSString).abbreviatingWithTildeInPath
            attributes.keywords = [url.lastPathComponent, "repository", "worktree"]
            return CSSearchableItem(
                uniqueIdentifier: url.path, domainIdentifier: domain, attributeSet: attributes)
        }
    }

    /// The repo a Spotlight pick asks for: its item's identifier is the repo's path.
    static func path(from activity: NSUserActivity) -> String? {
        guard activity.activityType == CSSearchableItemActionType else { return nil }
        return activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
    }
}

/// Takes Spotlight picks, which AppKit hands the app delegate, not SwiftUI's windows, and opens
/// them as `seam <path>` does: a `seam://` URL sent to this app, which routes it to the repo's
/// window or a new one.
public final class SeamAppDelegate: NSObject, NSApplicationDelegate {
    var send: @MainActor (URL) -> Void = { url in
        NSWorkspace.shared.open(
            [url], withApplicationAt: Bundle.main.bundleURL,
            configuration: NSWorkspace.OpenConfiguration())
    }
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")

    public func application(
        _ application: NSApplication, continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard let path = SpotlightRepoIndex.path(from: userActivity),
            let url = SeamURL(path: path).url
        else { return false }
        logger.info("spotlight opens \(path, privacy: .public)")
        send(url)
        return true
    }
}
