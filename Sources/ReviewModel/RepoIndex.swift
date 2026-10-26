import Foundation

/// Recent repositories for the system to find (SPEC §7.1): Spotlight, on macOS.
public protocol RepoIndex: Sendable {
    /// Makes Seam's Spotlight entries exactly these repos.
    func replace(with repositories: [URL]) async
}

/// Indexes nothing, for tests and previews.
public struct NoRepoIndex: RepoIndex {
    public init() {}
    public func replace(with repositories: [URL]) async {}
}
