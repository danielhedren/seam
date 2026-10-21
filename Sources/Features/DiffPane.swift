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
        view.onExpand = { [session] path, gap, direction in
            session.selected?.expand(path, gap: gap, direction)
        }
        return view
    }

    func updateNSView(_ view: DiffScrollView, context: Context) {
        session.diff.view = view
        view.isStale = review.showsProgress
        let shown = Coordinator.Shown(
            id: review.id, version: review.diffVersion, mode: review.mode,
            collapsed: review.collapsed, contentsVersion: review.contentsVersion,
            syntaxVersion: review.syntaxVersion, wraps: review.wraps,
            expansions: review.expansions)
        guard shown != context.coordinator.shown else { return }
        let previous = context.coordinator.shown
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
            case .missingDirectory:
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
        }
    }
}
