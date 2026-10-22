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
    private(set) var openWindows: Set<String> = []
    /// The repos with a window, in the order they opened, reopened at the next launch. Quitting
    /// leaves it as it is; closing a window takes that repo out.
    private(set) var workspace: [String]
    /// File › Open Recent; refreshed whenever a window opens a repo.
    var recent: [URL] = []
    /// The workspace and launch argument open once, not in every new welcome window.
    var launchHandled = false
    /// The window the next `tabsToAdopt` new windows join as tabs: File › New Tab, and a
    /// restored workspace.
    @ObservationIgnored weak var tabHost: NSWindow?
    @ObservationIgnored var tabsToAdopt = 0
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private let defaults: UserDefaults
    private static let workspaceKey = "seam.workspace"
    /// The frame AppKit saves and restores; the first window to claim it holds it.
    private static let frameName = "Seam"

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

    func adopt(_ window: NSWindow) {
        _ = window.setFrameAutosaveName(Self.frameName)
        guard tabsToAdopt > 0, let host = tabHost, host !== window else { return }
        tabsToAdopt -= 1
        if tabsToAdopt == 0 { tabHost = nil }
        // SwiftUI sizes a new window once it's on screen, and a tab group takes the size of a
        // window joining it; joining on the next turn and matching the host keeps the group's.
        Task { @MainActor in
            let frame = host.frame
            host.addTabbedWindow(window, ordered: .above)
            window.setFrame(frame, display: true)
            window.makeKeyAndOrderFront(nil)
        }
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
    }

    private static let windowID = "repository"

    public var body: some Scene {
        WindowGroup(id: Self.windowID, for: URL.self) { $url in
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
                }, installCommandLineTool: installTool, newTab: newTab,
                newWindow: { openWindow(id: Self.windowID) })
        }
        Settings {
            SettingsView(settings: services.settings)
        }
    }

    /// ⌘T, as in Safari: a welcome window, as a tab of the frontmost one.
    private func newTab() {
        requests.tabHost = NSApp.keyWindow
        requests.tabsToAdopt = 1
        openWindow(id: Self.windowID)
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
    @State private var window: NSWindow?

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
        // The window's title names its tab; the toolbar has no room to repeat it.
        .navigationTitle(url?.lastPathComponent ?? String(localized: "New Tab", bundle: .module))
        .toolbar(removing: .title)
        .background(
            WindowReader { found in
                window = found
                requests.adopt(found)
            }
        )
        .task { await launch() }
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

    /// The first window reopens the last workspace, the first repo in itself and the rest as its
    /// tabs, then opens the launch argument (`seam`, `make run`) among them.
    private func launch() async {
        guard !requests.launchHandled else { return }
        requests.launchHandled = true
        let saved = requests.workspace.filter { FileManager.default.fileExists(atPath: $0) }
        if url == nil, let first = saved.first {
            let rest = saved.dropFirst()
            requests.tabHost = window
            requests.tabsToAdopt = window == nil ? 0 : rest.count
            url = URL(fileURLWithPath: first, isDirectory: true)
            for path in rest { openWindow(value: URL(fileURLWithPath: path, isDirectory: true)) }
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
                Button(String(localized: "Open Repository…", bundle: .module), action: choose)
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
        // A toolbar like a repo window's, so the tab bar stays put when switching tabs.
        .toolbar {
            ToolbarItem {
                Button {
                    choose()
                } label: {
                    Label(
                        String(localized: "Open Repository…", bundle: .module),
                        systemImage: "folder")
                }
                .help(String(localized: "Open Repository… (⌘O)", bundle: .module))
            }
        }
        .task {
            recent = await services.store.recentRepositories()
            requests.recent = recent
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { start(url) }
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
