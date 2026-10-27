import Foundation

/// The `seam://open?path=…&base=…&thread=…` contract between the `seam` command, notifications
/// and the app (SPEC §13).
public struct SeamURL: Equatable, Sendable {
    public var path: String
    public var base: String?
    /// A thread to open once the worktree shows.
    public var thread: String?

    public init(path: String, base: String? = nil, thread: String? = nil) {
        self.path = path
        self.base = base
        self.thread = thread
    }

    public init?(_ url: URL) {
        guard url.scheme == "seam", url.host() == "open",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let path = items.first(where: { $0.name == "path" })?.value, !path.isEmpty
        else { return nil }
        self.path = path
        base = items.first { $0.name == "base" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        thread = items.first { $0.name == "thread" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "seam"
        components.host = "open"
        components.queryItems =
            [URLQueryItem(name: "path", value: path)]
            + (base.map { [URLQueryItem(name: "base", value: $0)] } ?? [])
            + (thread.map { [URLQueryItem(name: "thread", value: $0)] } ?? [])
        return components.url
    }
}
