import GitKit
import ReviewModel
import SeamCore

extension SeamServices {
    @MainActor
    public static func live() -> SeamServices {
        var services = SeamServices(
            git: CLIGitClient(), watcher: SystemFileWatcher(), clock: ContinuousClock(),
            store: JSONStateStore(), threads: ThreadStore(),
            settings: AppSettings(locateApp: MacPlatform.locateApp),
            spotlight: SpotlightRepoIndex(), github: .live(), platform: MacPlatform())
        services.launcher = ShellLauncher(locateApp: MacPlatform.locateApp)
        return services
    }
}
