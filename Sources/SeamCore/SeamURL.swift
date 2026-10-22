import Foundation

/// The `seam://open?path=…&base=…` contract between the `seam` command and the app (SPEC §13).
public struct SeamURL: Equatable, Sendable {
    public var path: String
    public var base: String?

    public init(path: String, base: String? = nil) {
        self.path = path
        self.base = base
    }

    public init?(_ url: URL) {
        guard url.scheme == "seam", url.host() == "open",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let path = items.first(where: { $0.name == "path" })?.value, !path.isEmpty
        else { return nil }
        self.path = path
        base = items.first { $0.name == "base" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "seam"
        components.host = "open"
        components.queryItems =
            [URLQueryItem(name: "path", value: path)]
            + (base.map { [URLQueryItem(name: "base", value: $0)] } ?? [])
        return components.url
    }
}
