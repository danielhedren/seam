import DiffModel
import DiffView
import ReviewModel
import SeamCore
import SwiftUI

/// Bridges the AppKit diff view into SwiftUI. Content is pushed only when the shown diff, mode
/// or collapsed set changes, so SwiftUI updates never reset the scroll position.
struct DiffRepresentable: NSViewRepresentable {
    let session: RepoSession
    let review: WorktreeReview

    final class Coordinator {
        struct Shown: Equatable {
            var id: String
            var version: Int
            var range: Int
            var narrowing: Narrowing
            var threads: [String: [ThreadMarker]]
            var resolvedMarks: [String: [ThreadMarker]]
            var sinceViewed: [String: String]
            var mode: DiffLayoutMode
            var collapsed: Set<String>
            var contentsVersion: Int
            var syntaxVersion: Int
            var wraps: Bool
            var viewed: ViewedMarks
            var expansions: [String: [Int: GapExpansion]]
            var draft: DraftMarker?
            var openThread: ThreadMarker?
        }
        var shown: Shown?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DiffScrollView {
        let view = DiffScrollView()
        view.keyBindings = CommandCatalog.diffKeyBindings
        session.diff.view = view
        view.onToggleCollapse = { [session] path in session.toggleCollapsed(path) }
        view.onFocusChange = { [session] focused in session.diffHasFocus = focused }
        view.onCurrentFileChange = { [session] path in session.noteReading(path) }
        view.onToggleViewed = { [session] path in session.toggleViewed(path, advance: false) }
        view.viewedHelp = FileActions.viewedHelp
        view.menuForFile = { [session] path in FileActions.menu(for: path, in: session) }
        view.onSearchResult = { [session] current, total in
            session.find.result = (current, total)
        }
        view.onOpenThread = { [session] id in session.openThread(id) }
        view.onCloseCard = { [session] in
            if session.selectedThreadID != nil {
                session.closeThread()
            } else {
                session.draft = nil
            }
        }
        // Reported from inside a SwiftUI update, so the change waits for the next turn.
        view.onOpenThreadHidden = { [session] hidden in
            Task { @MainActor in session.noteOpenThreadHidden(hidden) }
        }
        view.makeCardView = { [session] card in ThreadCardHost(session: session, card: card) }
        view.menuForLines = { [session] in FileActions.lineMenu(in: session) }
        view.onExpand = { [session] path, gap, direction in
            session.selected?.expand(path, gap: gap, direction)
        }
        return view
    }

    func updateNSView(_ view: DiffScrollView, context: Context) {
        session.diff.view = view
        view.isStale = review.showsProgress
        view.setFont(session.settings.font)
        defer { view.search(session.diffQuery) }
        let shown = Coordinator.Shown(
            id: review.id, version: review.diffVersion, range: review.shownRangeVersion,
            narrowing: review.narrowing, threads: review.threadMarkers,
            resolvedMarks: review.hiddenResolvedMarkers, sinceViewed: review.sinceViewed,
            mode: review.mode,
            collapsed: review.collapsed, contentsVersion: review.contentsVersion,
            syntaxVersion: review.syntaxVersion, wraps: review.wraps, viewed: review.viewed,
            expansions: review.expansions, draft: session.draftMarker(for: review),
            openThread: session.openThreadMarker(for: review))
        guard shown != context.coordinator.shown else { return }
        let previous = context.coordinator.shown
        // The view itself rebuilds only what a collapse or viewed toggle changes.
        guard var content = review.content else {
            // Not loaded yet, or the worktree's directory went missing: show nothing stale.
            if previous != nil {
                view.show(
                    DiffContent(review: ReviewDiff(scope: review.scope, files: [])),
                    position: .top)
                context.coordinator.shown = nil
            }
            return
        }
        let position: DiffScrollView.Position =
            if previous?.id == review.id {
                previous?.range == shown.range && previous?.narrowing == shown.narrowing
                    ? .keep : .top
            } else if let anchor = review.savedAnchor {
                .anchor(anchor)
            } else {
                .top
            }
        content.draft = shown.draft
        if let open = shown.openThread {
            let path = review.placedThreads.first { $0.id == open.id }?.thread.anchor.path ?? ""
            // A resolved thread shows while it's open, even with resolved threads hidden.
            if content.threads[path]?.contains(where: { $0.id == open.id }) != true {
                content.threads[path, default: []].append(open)
            }
            content.resolvedMarks[path]?.removeAll { $0.id == open.id }
            content.openThread = open.id
        }
        view.show(content, position: position)
        context.coordinator.shown = shown
    }
}

struct DiffPane: View {
    let session: RepoSession
    let review: WorktreeReview

    var body: some View {
        VStack(spacing: 0) {
            if let problem = review.problem {
                ProblemBanner(problem: problem, session: session)
            }
            if let problem = session.stateProblem {
                Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    Text(problem).lineLimit(2).textSelection(.enabled).help(problem)
                } actions: {
                    Button(String(localized: "Dismiss", bundle: .module)) {
                        session.dismissStateProblem()
                    }
                }
            }
            if let failure = session.threadFailure {
                Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
                    Text(failure).lineLimit(2).textSelection(.enabled).help(failure)
                } actions: {
                    Button(String(localized: "Dismiss", bundle: .module)) {
                        session.dismissThreadFailure()
                    }
                }
            }
            if let stale = review.staleParent {
                StaleParentBanner(stale: stale, session: session)
            } else if let base = review.pullRequestBase, let pullRequest = review.pullRequest {
                PullRequestBaseBanner(
                    number: pullRequest.number, base: base.name, session: session)
            }
            if session.find.isShown {
                FindBar(find: session.find)
                Divider()
            }
            ZStack {
                DiffRepresentable(session: session, review: review)
                if let empty = EmptyDiff.of(review) {
                    EmptyDiffView(empty: empty, session: session, review: review)
                }
                if review.showsProgress {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                }
            }
        }
    }
}

private struct EmptyDiffView: View {
    let empty: EmptyDiff
    let session: RepoSession
    let review: WorktreeReview

    var body: some View {
        ContentUnavailableView {
            Label(empty.title, systemImage: empty.systemImage)
        } description: {
            Text(empty.detail)
        } actions: {
            switch empty.action {
            case .clearFilter:
                Button(String(localized: "Clear Filter", bundle: .module)) {
                    review.fileFilter = ""
                }
            case .clearSearch:
                Button(String(localized: "Clear Search", bundle: .module)) {
                    review.search.text = ""
                }
            case .showAll:
                Button(String(localized: "Show All Changes", bundle: .module)) {
                    session.setScope(.all)
                }
            case nil:
                EmptyView()
            }
        }
    }
}

/// Recoverable problems show inline above the diff, never as alerts (SPEC §9). Banners keep a
/// neutral background: amber means review threads.
struct ProblemBanner: View {
    let problem: WorktreeReview.Problem
    let session: RepoSession

    var body: some View {
        Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
            Text(message).lineLimit(2).textSelection(.enabled).help(message)
        } actions: {
            switch problem {
            case .overrideGone:
                Button(String(localized: "Use Detected Base", bundle: .module)) {
                    session.setBaseOverride(nil)
                }
            case .gitFailed:
                Button(String(localized: "Retry", bundle: .module)) { session.reload() }
            case .editorFailed, .seenGone:
                Button(String(localized: "Dismiss", bundle: .module)) {
                    session.selected?.dismissNotice()
                }
            case .missingDirectory:
                EmptyView()
            }
        }
    }

    private var message: String {
        switch problem {
        case .missingDirectory:
            String(
                localized:
                    "This worktree's directory is missing. If it was deleted, “git worktree prune” takes it off the list.",
                bundle: .module)
        case .overrideGone(let ref):
            String(localized: "The chosen base \(ref) no longer exists.", bundle: .module)
        case .gitFailed(let detail): detail
        case .editorFailed(let detail):
            String(localized: "Couldn't open the editor: \(detail)", bundle: .module)
        case .seenGone(let path):
            String(
                localized:
                    "Seam no longer has the version of \(path) you marked viewed, so it can only show the full diff.",
                bundle: .module)
        }
    }
}

/// The diff's find bar: searches as you type, Return for the next match, Escape to close.
struct FindBar: View {
    @Bindable var find: FindState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(String(localized: "Find in diff", bundle: .module), text: $find.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { find.move(by: 1) }
            Text(status).foregroundStyle(.secondary).monospacedDigit()
            Button {
                find.move(by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(find.result.total == 0)
            .help(
                CommandCatalog.help(
                    String(localized: "Previous match", bundle: .module), command: "find-previous"))
            Button {
                find.move(by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(find.result.total == 0)
            .help(
                CommandCatalog.help(
                    String(localized: "Next match", bundle: .module), command: "find-next"))
            Button(String(localized: "Done", bundle: .module)) { find.close() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { focused = true }
        .onChange(of: find.focusRequests) {
            focused = true
            selectFieldText()
        }
        .onExitCommand { find.close() }
    }

    /// A field selects its text when it gains focus, but not when ⌘F is pressed again while it
    /// already has it; then the new query must still be selected so typing replaces it.
    private func selectFieldText() {
        Task { @MainActor in
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor
            else { return }
            editor.selectAll(nil)
        }
    }

    private var status: String {
        guard !find.query.isEmpty else { return "" }
        guard let current = find.result.current else {
            return String(localized: "No matches", bundle: .module)
        }
        return String(localized: "\(current) of \(find.result.total)", bundle: .module)
    }
}

/// "Parent X looks merged": non-blocking, with the suggested base one click away (SPEC §5.4).
struct StaleParentBanner: View {
    let stale: StaleParent
    let session: RepoSession

    var body: some View {
        Banner(systemImage: "arrow.triangle.merge", tint: .accentColor) {
            if case .pullRequestMerged(let number) = stale.reason {
                Text(
                    "Parent \(stale.parent)'s pull request #\(String(number)) merged. Diff against \(stale.suggestion.name) instead?",
                    bundle: .module)
            } else {
                Text(
                    "Parent \(stale.parent) looks merged. Diff against \(stale.suggestion.name) instead?",
                    bundle: .module)
            }
        } actions: {
            Button(String(localized: "Keep \(stale.parent)", bundle: .module)) {
                session.dismissStaleParent()
            }
            Button(String(localized: "Use \(stale.suggestion.name)", bundle: .module)) {
                session.setBaseOverride(stale.suggestion.ref)
            }
        }
    }
}

/// The worktree's open PR merges into another branch than the detected parent (SPEC §7.8).
struct PullRequestBaseBanner: View {
    let number: Int
    let base: String
    let session: RepoSession

    var body: some View {
        Banner(systemImage: "arrow.triangle.pull", tint: .accentColor) {
            Text(
                "Pull request #\(String(number)) merges into \(base). Diff against \(base) instead?",
                bundle: .module)
        } actions: {
            Button(String(localized: "Keep Detected Base", bundle: .module)) {
                session.dismissPullRequestBase()
            }
            Button(String(localized: "Use \(base)", bundle: .module)) {
                session.usePullRequestBase()
            }
        }
    }
}

/// A full-width strip above the diff: icon, message, and its buttons at the trailing edge.
private struct Banner<Message: View, Actions: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder let message: Message
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).foregroundStyle(tint)
                message.frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.background.secondary)
            Divider()
        }
    }
}
