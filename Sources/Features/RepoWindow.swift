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
            get: {
                switch session.columns {
                case .all: .all
                case .filesAndDiff: .doubleColumn
                case .diffOnly: .detailOnly
                }
            },
            set: { visibility in
                session.columns =
                    switch visibility {
                    case .detailOnly: .diffOnly
                    case .doubleColumn: .filesAndDiff
                    default: .all
                    }
            })
    }

    @ViewBuilder private var content: some View {
        switch session.state {
        case .opening:
            ProgressView(
                String(
                    localized: "Opening \(session.directory.lastPathComponent)…", bundle: .module)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView(message, systemImage: "folder.badge.questionmark")
        case .open:
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
                if let review = session.selected {
                    FileList(session: session, review: review, filterFocus: $filterFocused)
                        .focused($fileListFocused)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 300)
                } else {
                    Text("Select a worktree", bundle: .module).foregroundStyle(.secondary)
                }
            } detail: {
                if let review = session.selected {
                    DiffPane(session: session, review: review)
                        .toolbar { ReviewToolbar(session: session, review: review) }
                } else {
                    ContentUnavailableView(
                        String(localized: "No worktree selected", bundle: .module),
                        systemImage: "square.split.3x1")
                }
            }
            .onChange(of: fileListFocused) { _, focused in
                session.fileListHasFocus = focused && !filterFocused
            }
            .onChange(of: filterFocused) { _, focused in
                session.fileListHasFocus = fileListFocused && !focused
            }
        }
    }
}

/// Only view mode and reload; the diff gets the rest of the window (SPEC §9).
struct ReviewToolbar: ToolbarContent {
    let session: RepoSession
    let review: WorktreeReview

    var body: some ToolbarContent {
        ToolbarItem {
            Button {
                session.toggleMode()
            } label: {
                Label(
                    review.mode == .unified
                        ? String(localized: "Side by Side", bundle: .module)
                        : String(localized: "Unified", bundle: .module),
                    systemImage: review.mode == .unified ? "rectangle.split.2x1" : "rectangle")
            }
            .help(String(localized: "Toggle side-by-side (s)", bundle: .module))
        }
        ToolbarItem {
            Button {
                session.reload()
            } label: {
                Label(String(localized: "Reload", bundle: .module), systemImage: "arrow.clockwise")
            }
            .help(String(localized: "Reload (r)", bundle: .module))
        }
    }
}
