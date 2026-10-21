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

    @MainActor
    public init(services: SeamServices? = nil) {
        self.services = services ?? .live()
    }

    public var body: some Scene {
        WindowGroup(for: URL.self) { $url in
            Group {
                if let url {
                    RepoWindow(session: RepoSession(directory: url, services: services))
                        .id(url)
                } else {
                    WelcomeView(services: services) { target in
                        // The welcome window becomes the repo's window rather than opening another.
                        guard let resolved = await resolve(target) else { return false }
                        requests.pending[resolved.main.path] = .init(
                            worktree: resolved.worktree.path)
                        url = resolved.main
                        return true
                    }
                }
            }
            .onOpenURL { incoming in
                guard let request = SeamURL(incoming) else { return }
                Task { await route(request, from: $url) }
            }
            // A folder dropped on any window opens like `seam <folder>` would.
            .dropDestination(for: URL.self) { urls, _ in
                for dropped in urls where dropped.hasDirectoryPath {
                    Task { await route(SeamURL(path: dropped.path), from: $url) }
                }
                return urls.contains(where: \.hasDirectoryPath)
            }
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

    private func open(_ url: URL) {
        Task {
            guard let resolved = await resolve(url) else {
                openWindow(value: url)
                return
            }
            requests.pending[resolved.main.path] = .init(worktree: resolved.worktree.path)
            openWindow(value: resolved.main)
        }
    }

    /// A `seam://open` URL reaches the key window: it selects the worktree if it shows that
    /// repo, becomes the repo's window if it's the welcome window, and otherwise brings up the
    /// repo's own window.
    private func route(_ request: SeamURL, from window: Binding<URL?>) async {
        guard let resolved = await resolve(URL(fileURLWithPath: request.path, isDirectory: true))
        else { return }
        requests.pending[resolved.main.path] = .init(
            worktree: resolved.worktree.path, base: request.base)
        if window.wrappedValue == nil {
            window.wrappedValue = resolved.main
        } else if window.wrappedValue != resolved.main {
            openWindow(value: resolved.main)
        }
    }

    /// The repo's main worktree, which keys its window, and the worktree `url` is in.
    private func resolve(_ url: URL) async -> (main: URL, worktree: URL)? {
        let service = RepositoryService(git: services.git, fileSystem: services.fileSystem)
        guard let (repository, worktree) = try? await service.open(url),
            let main = try? await service.worktrees(of: repository).first(where: \.isMain)
        else { return nil }
        return (main.path, worktree)
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
