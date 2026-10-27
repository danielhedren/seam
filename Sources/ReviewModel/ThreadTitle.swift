import SeamCore

extension ReviewThread {
    /// The card's title, open or collapsed (SPEC §7.7): "Thread on line 12 · 3 comments ·
    /// resolved"; a pull request's says "GitHub thread on line 12 · #12 · 3 comments". The
    /// sticky header above already names the file.
    package func cardTitle(placement: ThreadPlacement) -> String {
        let shown = { if case .lines(let now) = placement { now } else { anchor.lines } }()
        let lines =
            shown.count == 1 ? "\(shown.lowerBound)" : "\(shown.lowerBound)–\(shown.upperBound)"
        let status = isResolved ? String(localized: " · resolved", bundle: .module) : ""
        if let github {
            let place =
                github.onFile
                ? String(localized: "GitHub thread on the file", bundle: .module)
                : anchor.side == .old
                    ? String(localized: "GitHub thread on old line \(lines)", bundle: .module)
                    : String(localized: "GitHub thread on line \(lines)", bundle: .module)
            return "\(place) · #\(github.pullRequest) · "
                + "\(Counted.comments(comments.count))\(status)"
        }
        let place =
            isNote
            ? String(localized: "Note on line \(lines)", bundle: .module)
            : anchor.side == .old
                ? String(localized: "Thread on old line \(lines)", bundle: .module)
                : String(localized: "Thread on line \(lines)", bundle: .module)
        return "\(place) · \(Counted.comments(comments.count))\(status)"
    }
}
