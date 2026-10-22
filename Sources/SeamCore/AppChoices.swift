import CryptoKit
import Foundation

/// What the reader chose in the app that the `seam` command must agree with (SPEC §13): the
/// detection settings and each branch's base override. The app writes them; both read them here.
public enum AppChoices {
    /// The app's defaults domain. The command isn't the app's bundle, so it names it.
    public static let defaultsDomain = "com.danielhedren.seam"
    public static let stateRoot = URL.applicationSupportDirectory.appending(
        path: "Seam", directoryHint: .isDirectory)

    static let defaultBaseKey = "seam.defaultBase"
    static let ignoredRefsKey = "seam.ignoredRefs"

    public static func detectionSettings(_ defaults: UserDefaults) -> DetectionSettings {
        var settings = DetectionSettings()
        if let base = defaults.string(forKey: defaultBaseKey), !base.isEmpty {
            settings.defaultBase = base
        }
        if let refs = defaults.stringArray(forKey: ignoredRefsKey) {
            settings.ignoredRefs = refs.map(Glob.init)
        }
        return settings
    }

    /// The common git dir identifies a repo across all of its worktrees.
    public static func stateFile(for repository: Repository, in root: URL = stateRoot) -> URL {
        let digest = SHA256.hash(data: Data(repository.commonDirectory.path.utf8))
        let id = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: id).appending(path: "state.json")
    }

    /// The parent the reader picked for `branch` (a full ref, as `git worktree list` gives it).
    public static func baseOverride(
        branch: String, of repository: Repository, in root: URL = stateRoot
    ) -> String? {
        struct State: Decodable { var baseOverrides: [String: String]? }
        guard let data = try? Data(contentsOf: stateFile(for: repository, in: root)) else {
            return nil
        }
        return (try? JSONDecoder().decode(State.self, from: data))?.baseOverrides?[branch]
    }
}
