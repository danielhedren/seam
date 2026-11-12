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
            spotlight: SpotlightRepoIndex(), github: .live(), platform: MacPlatform(),
            notifications: NotificationBell(store: JSONNotificationLogStore()))
        services.launcher = ShellLauncher(locateApp: MacPlatform.locateApp)
        let gh = GHLocator()
        services.pullRequestStore = { repository in
            CLIPullRequestStore(
                directory: AppChoices.stateFile(for: repository, in: AppChoices.stateRoot)
                    .deletingLastPathComponent().appending(path: "pulls.git"),
                objects: repository.commonDirectory.appending(path: "objects"),
                credentials: { await gh.locate() })
        }
        return services
    }
}
