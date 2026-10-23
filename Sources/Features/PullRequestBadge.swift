import GitKit
import SeamCore
import SwiftUI

/// A worktree's pull request: its number and one symbol for where it stands, plus one when CI
/// failed (SPEC §7.8). Each state has its own symbol, so the colour is never the only sign.
struct PullRequestBadge: View {
    let pullRequest: PullRequest
    var unpushed: Int?
    var read: Date?
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(pullRequest.marker))
                .foregroundStyle(tint(Self.color(pullRequest.marker)))
            Text(verbatim: "#\(pullRequest.number)")
            if pullRequest.ciFailed {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(tint(.red))
            }
        }
        .help(Self.help(pullRequest, unpushed: unpushed, read: read))
    }

    /// Colours are unreadable on a selected row's accent fill; the symbols still tell them apart.
    private func tint(_ color: Color) -> AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.foreground) : AnyShapeStyle(color)
    }

    static func symbol(_ marker: PullRequest.Marker) -> String {
        switch marker {
        case .draft: "circle.dashed"
        case .waitingForReview: "arrow.triangle.pull"
        case .reviewed: "text.bubble"
        case .approved: "checkmark.seal.fill"
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        }
    }

    static func color(_ marker: PullRequest.Marker) -> Color {
        switch marker {
        case .draft, .closed: .secondary
        case .waitingForReview: .blue
        case .reviewed: .orange
        case .approved: .green
        case .merged: .purple
        }
    }

    static func state(_ pullRequest: PullRequest) -> String {
        switch pullRequest.marker {
        case .draft: String(localized: "Draft", bundle: .module)
        case .waitingForReview: String(localized: "Waiting for review", bundle: .module)
        case .reviewed:
            pullRequest.review == .changesRequested
                ? String(localized: "Changes requested", bundle: .module)
                : String(localized: "Reviewed, not approved", bundle: .module)
        case .approved: String(localized: "Approved", bundle: .module)
        case .merged: String(localized: "Merged", bundle: .module)
        case .closed: String(localized: "Closed", bundle: .module)
        }
    }

    /// "Checks: 3 passed, 1 failed, 2 running"; nil without checks.
    static func checks(_ checks: PullRequest.Checks) -> String? {
        guard checks.total > 0 else { return nil }
        var parts: [String] = []
        if checks.passed > 0 {
            parts.append(String(localized: "\(checks.passed) passed", bundle: .module))
        }
        if checks.failed > 0 {
            parts.append(String(localized: "\(checks.failed) failed", bundle: .module))
        }
        if checks.pending > 0 {
            parts.append(String(localized: "\(checks.pending) running", bundle: .module))
        }
        return String(
            localized: "Checks: \(parts.joined(separator: ", "))", bundle: .module)
    }

    static func help(_ pullRequest: PullRequest, unpushed: Int?, read: Date?) -> String {
        var lines = ["#\(pullRequest.number) \(pullRequest.title)"]
        var status = [state(pullRequest)]
        if pullRequest.state == .open, let checks = checks(pullRequest.checks) {
            status.append(checks)
        }
        lines.append(status.joined(separator: " · "))
        if let unpushed {
            lines.append(
                unpushed == 1
                    ? String(localized: "1 local commit isn't in the pull request", bundle: .module)
                    : String(
                        localized: "\(unpushed) local commits aren't in the pull request",
                        bundle: .module))
        }
        if let read {
            let age = RelativeDateTimeFormatter().localizedString(for: read, relativeTo: .now)
            lines.append(String(localized: "Read from GitHub \(age)", bundle: .module))
        }
        return lines.joined(separator: "\n")
    }
}
