import AppKit
import DiffModel
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
    private(set) var openWindows: Set<String> = []
    /// The repos with a window, in the order they opened, reopened at the next launch. Quitting
    /// leaves it as it is; closing a window takes that repo out.
    private(set) var workspace: [String]
    /// File › Open Recent; refreshed whenever a window opens a repo.
    var recent: [URL] = []
    /// The workspace and launch argument open once, not in every new welcome window.
    var launchHandled = false
    /// The repo whose window `openWindow(for:)` is opening, for `placement()`.
    @ObservationIgnored var placing: String?
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private let defaults: UserDefaults
    private static let workspaceKey = "seam.workspace"
    /// Each repo's last window frame, kept after its window closes for when it opens again.
    private static let framesKey = "seam.windowFrames"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workspace = defaults.stringArray(forKey: Self.workspaceKey) ?? []
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.willTerminate() }
        }
    }

    func windowOpened(_ main: String) {
        openWindows.insert(main)
        guard !workspace.contains(main) else { return }
        workspace.append(main)
        defaults.set(workspace, forKey: Self.workspaceKey)
    }

    /// Windows also go away while the app quits, and those stay in the workspace.
    func windowClosed(_ main: String) {
        openWindows.remove(main)
        guard !isTerminating else { return }
        workspace.removeAll { $0 == main }
        defaults.set(workspace, forKey: Self.workspaceKey)
    }

    func willTerminate() {
        isTerminating = true
    }

    func savedFrame(for main: String) -> NSRect? {
        guard let text = defaults.dictionary(forKey: Self.framesKey)?[main] as? String else {
            return nil
        }
        let frame = NSRectFromString(text)
        return frame.isEmpty ? nil : frame
    }

    func saveFrame(_ frame: NSRect, for main: String) {
        var frames = defaults.dictionary(forKey: Self.framesKey) ?? [:]
        let text = NSStringFromRect(frame)
        guard frames[main] as? String != text else { return }
        frames[main] = text
        defaults.set(frames, forKey: Self.framesKey)
    }

    /// The repos the launch window and its siblings reopen, skipping any deleted since.
    var reopenedWorkspace: [String] {
        workspace.filter { FileManager.default.fileExists(atPath: $0) }
    }

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
        // One window per repo (SPEC §7.1); this also takes the tab items out of the menus.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    private static let windowID = "repository"
    private static let shortcutsID = "shortcuts"

    public var body: some Scene {
        WindowGroup(id: Self.windowID, for: URL.self) { $url in
            WindowRoot(url: $url, services: services)
                .environment(requests)
                .frame(minWidth: 900, minHeight: 500)
        }
        .defaultSize(width: 1280, height: 800)
        .defaultWindowPlacement { _, _ in requests.placement() }
        // The workspace reopens the windows, each in its repo's frame (WindowFrames.swift).
        .restorationBehavior(.disabled)
        .commands {
            SeamCommands(
                requests: requests, openRepository: choose, openRecent: open,
                clearRecent: {
                    Task {
                        await services.store.clearRecent()
                        requests.recent = []
                        await services.spotlight.replace(with: [])
                    }
                }, installCommandLineTool: installTool,
                newWindow: { openWindow(id: Self.windowID) },
                showShortcuts: { openWindow(id: Self.shortcutsID) })
        }
        Settings {
            SettingsView(settings: services.settings, github: services.github)
        }
        Window(String(localized: "Keyboard Shortcuts", bundle: .module), id: Self.shortcutsID) {
            ShortcutsView()
        }
        .defaultSize(width: 460, height: 640)
        // Help › Keyboard Shortcuts opens it; the Window menu lists it once it's open.
        .commandsRemoved()
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
        } catch {
            alert.messageText = String(
                localized: "Couldn't install the seam command", bundle: .module)
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    private func choose() {
        if let url = WelcomeView.chooseFolder() { open(url) }
    }

    /// From the menu bar, which has no window of its own to reuse.
    private func open(_ url: URL) {
        Task {
            guard let resolved = await RepoLocator(services: services).resolve(url) else {
                openWindow(value: url)
                return
            }
            requests.pending[resolved.main.path] = .init(worktree: resolved.worktree.path)
            requests.openWindow(for: resolved.main) { openWindow(value: resolved.main) }
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
    @State private var frame = WindowFrameKeeper()
    @State private var dropping = false

    var body: some View {
        Group {
            if let url {
                RepoWindow(session: RepoSession(directory: url, services: services)).id(url)
            } else {
                WelcomeView(services: services, dropping: dropping) { target in
                    await route(SeamURL(path: target.path))
                }
            }
        }
        // The Window menu, Mission Control and ⌘` still name the window. The toolbar shows no
        // title: macOS 26's toolbar title takes clicks without moving the window, which left
        // a dead spot in the bar; the worktree list names the repo instead.
        .navigationTitle(url?.lastPathComponent ?? String(localized: "Seam", bundle: .module))
        .toolbar(removing: .title)
        .background(
            WindowReader { window in
                // The launch window turns into the workspace's first repo (`launch()`).
                let launching = requests.launchHandled ? nil : requests.reopenedWorkspace.first
                frame.attach(window, repo: url?.path ?? launching, frames: requests)
            }
        )
        .onChange(of: url) { frame.track(url?.path) }
        .task { await launch() }
        // Existing windows take seam:// URLs rather than SwiftUI opening one per URL.
        .handlesExternalEvents(preferring: ["seam"], allowing: ["*"])
        .onOpenURL { incoming in
            guard let request = SeamURL(incoming) else { return }
            Task { await route(request) }
        }

        // A folder dropped on any window opens like `seam <folder>` would.
        .dropDestination(
            for: URL.self,
            action: { urls, _ in
                guard let folder = urls.first(where: \.hasDirectoryPath) else { return false }
                Task { await route(SeamURL(path: folder.path)) }
                return true
            }, isTargeted: { dropping = $0 })
    }

    /// The first window reopens the last workspace, the first repo in itself and the rest in
    /// windows of their own, then opens the launch argument (`seam`, `make run`) among them.
    private func launch() async {
        guard !requests.launchHandled else { return }
        requests.launchHandled = true
        let saved = requests.reopenedWorkspace
        if url == nil, let first = saved.first {
            url = URL(fileURLWithPath: first, isDirectory: true)
            for path in saved.dropFirst() {
                let main = URL(fileURLWithPath: path, isDirectory: true)
                requests.openWindow(for: main) { openWindow(value: main) }
            }
        }
        if let path = WelcomeView.launchPath() { _ = await route(SeamURL(path: path)) }
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
        switch OpenRoute.decide(
            repo: resolved.main.path, shown: url?.path, open: requests.openWindows)
        {
        case .here: break
        case .becomeRepo: url = resolved.main
        case .repoWindow(let closesWelcome):
            requests.openWindow(for: resolved.main) { openWindow(value: resolved.main) }
            if closesWelcome { dismiss() }
        }
        return true
    }
}

/// Where an open request for a repo lands (SPEC §7.1, §13): one window per repo.
enum OpenRoute: Equatable {
    /// This window shows the repo: it selects the worktree.
    case here
    /// This is a welcome window and the repo has none: it becomes the repo's.
    case becomeRepo
    /// The repo's own window, opened or brought up; a welcome window that asked goes away.
    case repoWindow(closesWelcome: Bool)

    static func decide(repo: String, shown: String?, open: Set<String>) -> OpenRoute {
        if shown == repo { return .here }
        if shown == nil, !open.contains(repo) { return .becomeRepo }
        return .repoWindow(closesWelcome: shown == nil)
    }
}

/// Hands over the window a view lands in, for the AppKit calls SwiftUI has no word for.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    final class Reader: NSView {
        var found: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found?(window) }
        }
    }

    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.found = found
        return view
    }

    func updateNSView(_ view: Reader, context: Context) {}
}

struct WelcomeView: View {
    let services: SeamServices
    /// Turns this window into the repo's window; false when `url` isn't in a repository.
    let open: (URL) async -> Bool
    /// A folder is being dragged over the window, which opens it when dropped.
    var dropping = false
    @Environment(OpenRequests.self) private var requests
    @State private var recent: [URL]
    @State private var opening: URL?
    @State private var failure: String?

    /// `recent` shows until the store's list arrives.
    init(
        services: SeamServices, recent: [URL] = [], dropping: Bool = false,
        open: @escaping (URL) async -> Bool
    ) {
        self.services = services
        self.open = open
        self.dropping = dropping
        _recent = State(initialValue: recent)
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Seam", bundle: .module).font(.largeTitle.bold())
                Text(
                    "Review each worktree against the branch it was cut from.", bundle: .module
                )
                .foregroundStyle(.secondary)
            }
            if let opening {
                ProgressView(
                    String(localized: "Opening \(opening.lastPathComponent)…", bundle: .module))
            } else {
                VStack(spacing: 8) {
                    Button(String(localized: "Open Repository…", bundle: .module), action: choose)
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                    Text("or drop a folder here", bundle: .module)
                        .font(.callout).foregroundStyle(.secondary)
                    if let failure {
                        Text(failure).foregroundStyle(.red)
                    }
                }
                if !recent.isEmpty {
                    // A short window lists fewer; File › Open Recent has them all.
                    ViewThatFits(in: .vertical) {
                        RecentRepositoryList(urls: recent, open: start)
                        RecentRepositoryList(urls: Array(recent.prefix(5)), open: start)
                        RecentRepositoryList(urls: Array(recent.prefix(2)), open: start)
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                    )
                    .padding(12)
            }
        }
        // A toolbar like a repo window's, so opening a repo here doesn't change the titlebar.
        .toolbar {
            ToolbarItem {
                Button {
                    choose()
                } label: {
                    Label(
                        String(localized: "Open Repository…", bundle: .module),
                        systemImage: "folder")
                }
                .help(
                    CommandCatalog.help(
                        String(localized: "Open Repository…", bundle: .module),
                        shortcut: CommandCatalog.openRepository))
            }
        }
        .task {
            recent = await services.store.recentRepositories()
            requests.recent = recent
        }
    }

    private func choose() {
        if let url = Self.chooseFolder() { start(url) }
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Open", bundle: .module)
        return panel.runModal() == .OK ? panel.url : nil
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
    nonisolated static func launchPath(_ arguments: [String] = CommandLine.arguments) -> String? {
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

/// The welcome window's recent repositories, newest first: name, then where it is.
private struct RecentRepositoryList: View {
    let urls: [URL]
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent", bundle: .module)
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 10)
            VStack(spacing: 0) {
                ForEach(urls, id: \.self) { url in RecentRepositoryRow(url: url) { open(url) } }
            }
            .padding(4)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(width: 440)
    }
}

private struct RecentRepositoryRow: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).fontWeight(.medium)
                    Text((url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                hovering ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.path)
    }
}
