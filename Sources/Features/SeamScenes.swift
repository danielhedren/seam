import AppKit
import DiffView
import Observation
import SeamCore
import SwiftUI

/// What an open request asks for, keyed by the repo's main worktree. One window per repo
/// (SPEC §7.1), so opening any worktree of an open repo selects it in the existing window.
@MainActor
@Observable
final class OpenRequests {
    struct Request: Equatable {
        var worktree: String
        /// From `seam --base`: set as the worktree's base override once it's selected.
        var base: String?
    }

    var pending: [String: Request] = [:]
    /// Main worktrees that have a window, so a welcome window doesn't become a second one.
    var openWindows: Set<String> = []
    /// File › Open Recent; refreshed whenever a window opens a repo.
    var recent: [URL] = []
    /// The launch argument opens a repo once, not in every new welcome window.
    var launchHandled = false

    func take(_ main: String) -> Request? {
        pending.removeValue(forKey: main)
    }
}

/// The app's scenes; the app target only instantiates this.
public struct SeamScenes: Scene {
    private let services: SeamServices
    @State private var requests = OpenRequests()
    @Environment(\.openWindow) private var openWindow

    public init(services: SeamServices) {
        self.services = services
    }

    public var body: some Scene {
        WindowGroup(for: URL.self) { $url in
            WindowRoot(url: $url, services: services)
                .environment(requests)
                .frame(minWidth: 900, minHeight: 500)
        }
        .commands {
            SeamCommands(
                requests: requests, openRepository: choose, openRecent: open,
                clearRecent: {
                    Task {
                        await services.store.clearRecent()
                        requests.recent = []
                    }
                }, installCommandLineTool: installTool)
        }
        Settings {
            SettingsView(settings: services.settings)
        }
    }

    /// A one-off answer to an explicit menu command, so an alert is the right shape (SPEC §9).
    private func installTool() {
        let alert = NSAlert()
        do {
            try CommandLineTool.install(
                script: Bundle.main.url(forResource: "seam", withExtension: nil))
            alert.messageText = String(localized: "Installed the seam command", bundle: .module)
            alert.informativeText = String(
                localized:
                    "\(CommandLineTool.defaultLink.path) now opens Seam. Make sure ~/.local/bin is on your PATH.",
                bundle: .module)
        } catch CommandLineTool.Failure.occupied(let path) {
            alert.messageText = String(
                localized: "Couldn't install the seam command", bundle: .module)
            alert.informativeText = String(
                localized: "\(path) already exists and isn't Seam's. Remove it and try again.",
                bundle: .module)
        } catch {
            alert.messageText = String(
                localized: "Couldn't install the seam command", bundle: .module)
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Open", bundle: .module)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// From the menu bar, which has no window of its own to reuse.
    private func open(_ url: URL) {
        Task {
            guard let resolved = await RepoLocator(services: services).resolve(url) else {
                openWindow(value: url)
                return
            }
            requests.pending[resolved.main.path] = .init(worktree: resolved.worktree.path)
            openWindow(value: resolved.main)
        }
    }
}

/// A folder's repo, keyed by its main worktree (which keys the repo's window), and the worktree
/// the folder is in.
struct RepoLocator {
    let services: SeamServices

    func resolve(_ url: URL) async -> (main: URL, worktree: URL)? {
        let service = RepositoryService(git: services.git, fileSystem: services.fileSystem)
        guard let (repository, worktree) = try? await service.open(url),
            let main = try? await service.worktrees(of: repository).first(where: \.isMain)
        else { return nil }
        return (main.path, worktree)
    }
}

/// One window: the welcome screen or a repo, and where opens arriving at it go.
struct WindowRoot: View {
    @Binding var url: URL?
    let services: SeamServices
    @Environment(OpenRequests.self) private var requests
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let url {
                RepoWindow(session: RepoSession(directory: url, services: services)).id(url)
            } else {
                WelcomeView(services: services) { target in
                    await route(SeamURL(path: target.path))
                }
            }
        }
        // Existing windows take seam:// URLs rather than SwiftUI opening one per URL.
        .handlesExternalEvents(preferring: ["seam"], allowing: ["*"])
        .onOpenURL { incoming in
            guard let request = SeamURL(incoming) else { return }
            Task { await route(request) }
        }
        // A folder dropped on any window opens like `seam <folder>` would.
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: \.hasDirectoryPath) else { return false }
            Task { await route(SeamURL(path: folder.path)) }
            return true
        }
    }

    /// One window per repo (SPEC §7.1): a window showing the repo selects the worktree, a welcome
    /// window becomes the repo's window unless one is already open, and anything else brings up
    /// the repo's own. False when the folder isn't in a repository.
    private func route(_ request: SeamURL) async -> Bool {
        guard
            let resolved = await RepoLocator(services: services).resolve(
                URL(fileURLWithPath: request.path, isDirectory: true))
        else { return false }
        requests.pending[resolved.main.path] = .init(
            worktree: resolved.worktree.path, base: request.base)
        if url == resolved.main { return true }
        if url == nil, !requests.openWindows.contains(resolved.main.path) {
            url = resolved.main
            return true
        }
        openWindow(value: resolved.main)
        if url == nil { dismiss() }
        return true
    }
}

struct WelcomeView: View {
    let services: SeamServices
    /// Turns this window into the repo's window; false when `url` isn't in a repository.
    let open: (URL) async -> Bool
    @Environment(OpenRequests.self) private var requests
    @State private var recent: [URL] = []
    @State private var opening: URL?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Seam", bundle: .module).font(.largeTitle.bold())
            if let opening {
                ProgressView(
                    String(localized: "Opening \(opening.lastPathComponent)…", bundle: .module))
            } else {
                Text("Open a repository to review its worktrees.", bundle: .module)
                    .foregroundStyle(.secondary)
                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
                Button(String(localized: "Open Repository…", bundle: .module)) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { start(url) }
                }
                .keyboardShortcut(.defaultAction)
                if !recent.isEmpty {
                    Divider().frame(width: 280)
                    ForEach(recent, id: \.self) { url in
                        Button(url.path) { start(url) }.buttonStyle(.link)
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if !requests.launchHandled, let path = Self.launchPath() {
                requests.launchHandled = true
                start(URL(fileURLWithPath: path, isDirectory: true))
            }
            recent = await services.store.recentRepositories()
            requests.recent = recent
        }
    }

    private func start(_ url: URL) {
        opening = url
        failure = nil
        Task {
            if !(await open(url)) {
                failure = String(
                    localized: "\(url.path) is not in a git repository.", bundle: .module)
            }
            opening = nil
        }
    }

    /// `open -a Seam --args <path>` opens that repo. `-Key value` pairs are user defaults that
    /// AppKit and Xcode pass, so their values are skipped.
    static func launchPath(_ arguments: [String] = CommandLine.arguments) -> String? {
        var remaining = arguments.dropFirst()[...]
        while let argument = remaining.popFirst() {
            if argument.hasPrefix("-") {
                if let next = remaining.first, !next.hasPrefix("-") { remaining.removeFirst() }
                continue
            }
            return argument
        }
        return nil
    }
}
