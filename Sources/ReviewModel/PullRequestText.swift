import Foundation
import GitKit

/// How a pull request's state reads, in its badge's tooltip and once the review is done
/// (SPEC §7.8).
package enum PullRequestText {
    package static func state(_ pullRequest: PullRequest) -> String {
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
    package static func checks(_ checks: PullRequest.Checks) -> String? {
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

    package static func unpushed(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 local commit isn't in the pull request", bundle: .module)
            : String(
                localized: "\(count) local commits aren't in the pull request", bundle: .module)
    }

    package static func help(_ pullRequest: PullRequest, unpushed: Int?, read: Date?) -> String {
        var lines = ["#\(pullRequest.number) \(pullRequest.title)"]
        var status = [state(pullRequest)]
        if pullRequest.state == .open, let checks = checks(pullRequest.checks) {
            status.append(checks)
        }
        lines.append(status.joined(separator: " · "))
        if let unpushed { lines.append(Self.unpushed(unpushed)) }
        if let read {
            #if canImport(Darwin)
                let age = RelativeDateTimeFormatter().localizedString(for: read, relativeTo: .now)
            #else
                let age = read.formatted(.relative(presentation: .numeric))
            #endif
            lines.append(String(localized: "Read from GitHub \(age)", bundle: .module))
        }
        return lines.joined(separator: "\n")
    }
}
