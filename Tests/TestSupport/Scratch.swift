import Foundation
import Synchronization

/// Scratch settings and folders for tests, removed when the test process exits. A suite named by
/// an absolute path keeps its plist there rather than in ~/Library/Preferences, where a named
/// suite stays for good; Swift Testing has no per-test teardown to remove one.
public enum Scratch {
    private struct Made {
        var paths: [URL] = []
        var cleansUp = false
    }

    private static let made = Mutex(Made())
    private static let defaultsFolder = path("seam-defaults")

    /// A `UserDefaults` suite of its own.
    public static func defaults(_ prefix: String) -> UserDefaults {
        try? FileManager.default.createDirectory(
            at: defaultsFolder, withIntermediateDirectories: true)
        let suite = defaultsFolder.appending(path: "\(prefix)-\(UUID().uuidString)").path
        return UserDefaults(suiteName: suite) ?? UserDefaults()
    }

    /// A path in the temporary folder, `<prefix>-<UUID>`, not yet created.
    public static func path(_ prefix: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "\(prefix)-\(UUID().uuidString)")
        let first = made.withLock { made in
            made.paths.append(url)
            defer { made.cleansUp = true }
            return !made.cleansUp
        }
        if first { atexit { Scratch.removeAll() } }
        return url
    }

    private static func removeAll() {
        for url in made.withLock({ $0.paths }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
