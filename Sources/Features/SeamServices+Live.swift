import GitKit
import ReviewModel
import SeamCore

extension SeamServices {
    @MainActor
    public static func live() -> SeamServices {
        SeamServices(
            git: CLIGitClient(), watcher: SystemFileWatcher(), clock: ContinuousClock(),
            store: JSONStateStore(), threads: ThreadStore(), settings: AppSettings(),
            spotlight: SpotlightRepoIndex(), github: .live(), platform: MacPlatform())
    }
}
