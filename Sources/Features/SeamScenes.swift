import AppKit
import DiffView
import Observation
import SeamCore
import SwiftUI

/// Worktrees asked for by an open request, keyed by the repo's main worktree. One window per repo
/// (SPEC §7.1), so opening any worktree of an open repo selects it in the existing window.
@MainActor
@Observable
final class OpenRequests {
    var pending: [String: String] = [:]
    /// The launch argument opens a repo once, not in every new welcome window.
    var launchHandled = false

    init() {}

    func take(_ main: String) -> String? {
        pending.removeValue(forKey: main)
    }
}

/// The app's scenes; the app target only instantiates this.
public struct SeamScenes: Scene {
    private let services: SeamServices
    @State private var requests = OpenRequests()
    @Environment(\.openWindow) private var openWindow

    public init(services: SeamServices = .live) {
        self.services = services
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
                        requests.pending[resolved.main.path] = resolved.worktree.path
                        url = resolved.main
                        return true
                    }
                }
            }
            .environment(requests)
            .frame(minWidth: 900, minHeight: 500)
        }
        .commands {
            SeamCommands(openRepository: choose)
        }
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
            requests.pending[resolved.main.path] = resolved.worktree.path
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
