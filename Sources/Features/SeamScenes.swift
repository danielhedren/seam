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
                    WelcomeView(services: services, open: open)
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
            let service = RepositoryService(git: services.git, fileSystem: services.fileSystem)
            guard let (repository, worktree) = try? await service.open(url),
                let main = try? await service.worktrees(of: repository).first(where: \.isMain)
            else {
                openWindow(value: url)
                return
            }
            requests.pending[main.id] = worktree.path
            openWindow(value: main.path)
        }
    }
}

struct WelcomeView: View {
    let services: SeamServices
    @Environment(OpenRequests.self) private var requests
    let open: (URL) -> Void
    @State private var recent: [URL] = []

    var body: some View {
        VStack(spacing: 16) {
            Text("Seam", bundle: .module).font(.largeTitle.bold())
            Text("Open a repository to review its worktrees.", bundle: .module)
                .foregroundStyle(.secondary)
            Button(String(localized: "Open Repository…", bundle: .module)) {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { open(url) }
            }
            .keyboardShortcut(.defaultAction)
            if !recent.isEmpty {
                Divider().frame(width: 280)
                ForEach(recent, id: \.self) { url in
                    Button(url.path) { open(url) }.buttonStyle(.link)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            recent = await services.store.recentRepositories()
            if !requests.launchHandled, let path = Self.launchPath() {
                requests.launchHandled = true
                open(URL(fileURLWithPath: path, isDirectory: true))
            }
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
