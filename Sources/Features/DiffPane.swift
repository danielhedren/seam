import DiffView
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
            var mode: DiffLayoutMode
            var collapsed: Set<String>
            var contentsVersion: Int
            var syntaxVersion: Int
            var wraps: Bool
            var viewed: ViewedMarks
            var expansions: [String: [Int: GapExpansion]]
        }
        var shown: Shown?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DiffScrollView {
        let view = DiffScrollView()
        session.diff.view = view
        view.onToggleCollapse = { [session] path in session.toggleCollapsed(path) }
        view.onFocusChange = { [session] focused in session.diffHasFocus = focused }
        view.onCurrentFileChange = { [session] path in session.selected?.currentFile = path }
        view.onToggleViewed = { [session] path in session.toggleViewed(path, advance: false) }
        view.menuForFile = { [session] path in FileActions.menu(for: path, in: session) }
        view.onSearchResult = { [session] current, total in
            session.findResult = (current, total)
        }
        view.onExpand = { [session] path, gap, direction in
            session.selected?.expand(path, gap: gap, direction)
        }
        return view
    }

    func updateNSView(_ view: DiffScrollView, context: Context) {
        session.diff.view = view
        view.isStale = review.showsProgress
        view.setFont(session.settings.font)
        let shown = Coordinator.Shown(
            id: review.id, version: review.diffVersion, mode: review.mode,
            collapsed: review.collapsed, contentsVersion: review.contentsVersion,
            syntaxVersion: review.syntaxVersion, wraps: review.wraps, viewed: review.viewed,
            expansions: review.expansions)
        guard shown != context.coordinator.shown else { return }
        let previous = context.coordinator.shown
        // A viewed toggle only redraws headers; rebuilding rows would cost a 20k-line diff 75 ms.
        if var unmarked = previous, let content = review.content {
            unmarked.viewed = shown.viewed
            if unmarked == shown {
                view.setViewed(content.viewed)
                context.coordinator.shown = shown
                return
            }
        }
        guard let content = review.content else {
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
                .keep
            } else if let anchor = review.savedAnchor {
                .anchor(anchor)
            } else {
                .top
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
            if let stale = review.staleParent {
                StaleParentBanner(stale: stale, session: session, review: review)
            }
            if session.showsFind {
                FindBar(session: session)
                Divider()
            }
            ZStack {
                DiffRepresentable(session: session, review: review)
                if let message = emptyMessage {
                    ContentUnavailableView(message, systemImage: "checkmark.circle")
                }
                if review.showsProgress {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(12)
                }
            }
        }
    }

    private var emptyMessage: String? {
        guard let diff = review.diff, diff.files.isEmpty, review.problem == nil else { return nil }
        let parent = review.parentName ?? String(localized: "the base", bundle: .module)
        switch review.scope {
        case .all: return String(localized: "No changes against \(parent)", bundle: .module)
        case .committed: return String(localized: "No commits since \(parent)", bundle: .module)
        case .uncommitted: return String(localized: "No uncommitted changes", bundle: .module)
        }
    }
}

/// Recoverable problems show inline above the diff, never as alerts (SPEC §9).
struct ProblemBanner: View {
    let problem: WorktreeReview.Problem
    let session: RepoSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(message).lineLimit(2).textSelection(.enabled)
            Spacer()
            switch problem {
            case .overrideGone:
                Button(String(localized: "Use Detected Base", bundle: .module)) {
                    session.setBaseOverride(nil)
                }
            case .gitFailed:
                Button(String(localized: "Retry", bundle: .module)) { session.reload() }
            case .missingDirectory, .editorFailed:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.15))
        .accessibilityElement(children: .combine)
    }

    private var message: String {
        switch problem {
        case .missingDirectory:
            String(localized: "This worktree's directory is missing.", bundle: .module)
        case .overrideGone(let ref):
            String(localized: "The chosen base \(ref) no longer exists.", bundle: .module)
        case .gitFailed(let detail): detail
        case .editorFailed(let detail):
            String(localized: "Couldn't open the editor: \(detail)", bundle: .module)
        }
    }
}

/// The diff's find bar: searches as you type, Return for the next match, Escape to close.
struct FindBar: View {
    @Bindable var session: RepoSession
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(String(localized: "Find in diff", bundle: .module), text: $session.findQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { session.diff.moveToMatch(by: 1) }
                .onChange(of: session.findQuery) { _, query in session.diff.search(query) }
            Text(status).foregroundStyle(.secondary).monospacedDigit()
            Button {
                session.diff.moveToMatch(by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .accessibilityLabel(String(localized: "Previous match", bundle: .module))
            .disabled(session.findResult.total == 0)
            Button {
                session.diff.moveToMatch(by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .accessibilityLabel(String(localized: "Next match", bundle: .module))
            .disabled(session.findResult.total == 0)
            Button(String(localized: "Done", bundle: .module)) { session.closeFind() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { focused = true }
        .onChange(of: session.findFocusRequests) { focused = true }
        .onExitCommand { session.closeFind() }
    }

    private var status: String {
        guard !session.findQuery.isEmpty else { return "" }
        guard let current = session.findResult.current else {
            return String(localized: "No matches", bundle: .module)
        }
        return String(localized: "\(current) of \(session.findResult.total)", bundle: .module)
    }
}

/// "Parent X looks merged": non-blocking, with the suggested base one click away (SPEC §5.4).
struct StaleParentBanner: View {
    let stale: StaleParent
    let session: RepoSession
    let review: WorktreeReview

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(
                "Parent \(stale.parent) looks merged. Diff against \(stale.suggestion.name) instead?",
                bundle: .module)
            Spacer()
            Button(String(localized: "Use \(stale.suggestion.name)", bundle: .module)) {
                session.setBaseOverride(stale.suggestion.ref)
            }
            Button(String(localized: "Keep \(stale.parent)", bundle: .module)) {
                session.dismissStaleParent()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.1))
        .accessibilityElement(children: .contain)
    }
}
