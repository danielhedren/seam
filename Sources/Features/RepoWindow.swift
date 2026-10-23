import DiffView
import SeamCore
import SwiftUI

extension FocusedValues {
    @Entry var repoSession: RepoSession?
}

/// The three-pane review window for one repo (SPEC §7.1, §9).
struct RepoWindow: View {
    @State private var session: RepoSession
    @Environment(OpenRequests.self) private var requests
    @Environment(\.undoManager) private var undoManager
    @FocusState private var filterFocused: Bool
    @FocusState private var fileListFocused: Bool

    init(session: RepoSession) {
        _session = State(initialValue: session)
    }

    var body: some View {
        content
            .task {
                session.undoManager = undoManager
                await session.open()
                requests.recent = await session.recentRepositories()
                await handle(requests.take(session.directory.path))
            }
            .onChange(of: requests.pending) {
                // While opening, the .task above takes the request once the list is known.
                guard session.state == .open else { return }
                let request = requests.take(session.directory.path)
                Task { await handle(request) }
            }
            .onAppear { requests.windowOpened(session.directory.path) }
            .onDisappear {
                requests.windowClosed(session.directory.path)
                session.close()
            }
            .focusedSceneValue(\.repoSession, session)
            .onChange(of: session.filterFocusRequests) { filterFocused = true }
            // The search field may only appear with this update, so focus waits a turn for it.
            .onChange(of: session.searchFocusRequests) {
                Task { @MainActor in filterFocused = true }
            }
            .sheet(isPresented: Bindable(session).showsSwitcher) {
                WorktreeSwitcher(session: session)
            }
            .sheet(isPresented: Bindable(session).showsPalette) {
                CommandPalette(session: session)
            }
    }

    private func handle(_ request: OpenRequests.Request?) async {
        guard let request else { return }
        await session.handle(worktree: request.worktree, base: request.base)
    }

    /// The split view also changes visibility itself, when the user drags a column closed.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { session.showsWorktreeList ? .all : .doubleColumn },
            set: { session.showsWorktreeList = $0 == .all })
    }

    /// The split view and its toolbar are there from the first frame, whatever the state: a
    /// toolbar that appears once the repo opens grows the titlebar and moves the content down.
    private var content: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarSplit {
                WorktreeList(session: session)
            } bottom: {
                if let review = session.selected {
                    CommitList(session: session, review: review)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } content: {
            Group {
                if let review = session.selected {
                    FileList(session: session, review: review, filterFocus: $filterFocused)
                        .focused($fileListFocused)
                } else if session.state == .open {
                    Text("Select a worktree", bundle: .module).foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { ReviewToolbar(session: session, review: session.selected) }
        }
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .onChange(of: fileListFocused) { _, focused in
            session.fileListHasFocus = focused && !filterFocused
        }
        .onChange(of: filterFocused) { _, focused in
            session.fileListHasFocus = fileListFocused && !focused
        }
    }

    @ViewBuilder private var detail: some View {
        switch session.state {
        case .opening:
            OpeningProgress(
                name: session.directory.lastPathComponent, clock: session.services.clock)
        case .failed(let message):
            // The message can be git's whole stderr: too long for a title.
            ContentUnavailableView {
                Label(
                    String(
                        localized: "Couldn't open \(session.directory.lastPathComponent)",
                        bundle: .module),
                    systemImage: "folder.badge.questionmark")
            } description: {
                Text(message).textSelection(.enabled)
            }
        case .open:
            if let review = session.selected {
                DiffPane(session: session, review: review)
                    .inspector(isPresented: Bindable(session).showsThreadPanel) {
                        ThreadPanel(session: session, review: review)
                            .inspectorColumnWidth(min: 280, ideal: 340, max: 560)
                    }
            } else {
                ContentUnavailableView(
                    String(localized: "No worktree selected", bundle: .module),
                    systemImage: "square.split.3x1")
            }
        }
    }
}

/// View mode, reload and the thread panel; the diff gets the rest of the window (SPEC §9). Disabled rather
/// than left out without a worktree, so the toolbar keeps its items.
struct ReviewToolbar: ToolbarContent {
    let session: RepoSession
    let review: WorktreeReview?

    var body: some ToolbarContent {
        ToolbarItem {
            ViewModePicker(settings: session.settings)
                .disabled(review == nil)
        }
        ToolbarItem {
            Button {
                session.reload()
            } label: {
                Label(String(localized: "Reload", bundle: .module), systemImage: "arrow.clockwise")
            }
            .help(
                CommandCatalog.help(
                    String(localized: "Reload", bundle: .module), command: "reload")
            )
            .disabled(review == nil)
        }
        ToolbarItem {
            // On while the panel shows, like Xcode's inspector buttons.
            Toggle(isOn: Bindable(session).showsThreadPanel) {
                Label(String(localized: "Threads", bundle: .module), systemImage: "text.bubble")
            }
            .badge(review?.openThreadCount ?? 0)
            .help(
                CommandCatalog.help(
                    session.showsThreadPanel
                        ? String(localized: "Hide Threads", bundle: .module)
                        : String(localized: "Show Threads", bundle: .module),
                    command: "thread-panel")
            )
            .disabled(review == nil)
        }
    }
}

/// Both modes with the current one selected, so the control says what's showing. `s` and
/// View › Side by Side flip the same setting.
struct ViewModePicker: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Picker(selection: $settings.layoutMode) {
            Label(String(localized: "Unified", bundle: .module), systemImage: "rectangle")
                .tag(DiffLayoutMode.unified)
            Label(
                String(localized: "Side by Side", bundle: .module),
                systemImage: "rectangle.split.2x1"
            )
            .tag(DiffLayoutMode.split)
        } label: {
            Text("View Mode", bundle: .module)
        }
        .pickerStyle(.segmented)
        .help(
            CommandCatalog.help(
                String(localized: "Unified or side by side", bundle: .module),
                command: "side-by-side"))
    }
}

/// Shown only once opening takes 150 ms, so a fast open doesn't flash it (SPEC §9).
struct OpeningProgress: View {
    let name: String
    let clock: any Clock<Duration>
    @State private var isShown = false

    var body: some View {
        ProgressView(String(localized: "Opening \(name)…", bundle: .module))
            .opacity(isShown ? 1 : 0)
            .task {
                try? await clock.sleep(for: .milliseconds(150))
                if !Task.isCancelled { isShown = true }
            }
    }
}
