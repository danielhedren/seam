import GitKit
import ReviewModel
import SeamCore
import SwiftUI

/// Other people's open pull requests, a section of the worktree list after the worktrees (SPEC
/// §7.2.2). Until they can be reviewed here (M11), picking one opens it on GitHub.
struct PullRequestSection: View {
    let session: RepoSession

    /// Rows are tagged in the worktree list's id space, apart from every worktree path.
    static func tag(_ number: Int) -> String { WorktreeReview.id(ofPullRequest: number) }

    static func number(_ tag: String) -> Int? {
        tag.hasPrefix("pr:") ? Int(tag.dropFirst(3)) : nil
    }

    var body: some View {
        let listing = session.pullRequestListing
        Section {
            ForEach(listing.rows) { row in
                PullRequestListRow(
                    row: row, totals: session.pullRequestTotals[row.id],
                    hasNewCommits: session.pullRequestsWithNewCommits.contains(row.id)
                )
                .tag(Self.tag(row.id))
            }
            if listing.rows.isEmpty {
                Text(Self.empty(listing)).font(.callout).foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        } header: {
            HStack {
                Text(Self.header(listing)).lineLimit(1)
                Spacer(minLength: 4)
                PullRequestFilterMenu(session: session, listing: listing)
            }
        }
    }

    @ViewBuilder static func rowMenu(_ number: Int, in session: RepoSession) -> some View {
        Button(String(localized: "Open Pull Request in Browser", bundle: .module)) {
            session.openListedPullRequest(number)
        }
        Button(String(localized: "Copy Pull Request URL", bundle: .module)) {
            session.copyListedPullRequestURL(number)
        }
        Button(String(localized: "Copy Pull Request Number", bundle: .module)) {
            session.copyListedPullRequestNumber(number)
        }
        Button(String(localized: "Copy Worktree Command", bundle: .module)) {
            session.copyWorktreeCommand(for: number)
        }
        Divider()
        Button(String(localized: "Hide This Pull Request", bundle: .module)) {
            session.hidePullRequest(number)
        }
        if let author = session.pullRequestListing.rows.first(where: { $0.id == number })?
            .pullRequest.author, !author.isEmpty
        {
            Button(String(localized: "Hide Pull Requests by \(author)", bundle: .module)) {
                session.hidePullRequests(by: author)
            }
        }
    }

    /// "Pull Requests · 12 · 28 hidden", or "100 most recent of 230" past the limit.
    static func header(_ listing: PullRequestListing) -> String {
        let title = String(localized: "Pull Requests", bundle: .module)
        let count =
            listing.isCapped
            ? String(
                localized:
                    "\(String(PullRequestListing.limit)) most recent of \(String(listing.matching))",
                bundle: .module)
            : String(listing.matching)
        guard listing.hidden > 0 else { return "\(title) · \(count)" }
        let hidden = String(localized: "\(String(listing.hidden)) hidden", bundle: .module)
        return "\(title) · \(count) · \(hidden)"
    }

    static func empty(_ listing: PullRequestListing) -> String {
        listing.hidden > 0
            ? String(localized: "No pull requests match the filters.", bundle: .module)
            : String(localized: "No one else's pull requests are open.", bundle: .module)
    }
}

struct PullRequestListRow: View {
    let row: PullRequestListing.Row
    /// Counted once the PR is in the store.
    var totals: DiffStat?
    var hasNewCommits = false
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let pullRequest = row.pullRequest
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "#\(pullRequest.number)").monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(pullRequest.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                AgeText(date: pullRequest.updated).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                let marker = pullRequest.isDraft ? PullRequest.Marker.draft : .waitingForReview
                PullRequestBadge.stateIcon(marker).image.resizable().frame(width: 12, height: 12)
                    .foregroundStyle(
                        prominence == .increased
                            ? AnyShapeStyle(.foreground)
                            : AnyShapeStyle(PullRequestBadge.stateColor(marker))
                    )
                    .help(
                        pullRequest.isDraft
                            ? String(localized: "Draft", bundle: .module)
                            : String(localized: "Open", bundle: .module))
                Text(pullRequest.author).lineLimit(1).truncationMode(.middle)
                if row.isReviewRequested {
                    // In words, like a worktree's attention: it's what the reader scans for.
                    Text("review requested", bundle: .module).fontWeight(.semibold)
                        .foregroundStyle(
                            prominence == .increased
                                ? AnyShapeStyle(.foreground) : AnyShapeStyle(.orange))
                }
                if hasNewCommits {
                    Text("new commits", bundle: .module).fontWeight(.semibold)
                        .foregroundStyle(tint(.orange))
                }
                Spacer(minLength: 0)
                // Grey for 0, as on worktree rows: only real changes take a colour.
                if let totals, totals.files > 0 {
                    Text(verbatim: "+\(totals.additions)")
                        .foregroundStyle(totals.additions > 0 ? tint(.green) : grey)
                    Text(verbatim: "−\(totals.deletions)")
                        .foregroundStyle(totals.deletions > 0 ? tint(.red) : grey)
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .opacity(row.isHidden ? 0.5 : 1)
        .help(
            pullRequest.labels.isEmpty
                ? pullRequest.title : pullRequest.labels.joined(separator: ", "))
    }

    private var grey: AnyShapeStyle { AnyShapeStyle(.secondary) }

    private func tint(_ color: Color) -> AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.foreground) : AnyShapeStyle(color)
    }
}

/// The list's filters (SPEC §7.2.2): the switches, then every author and label the open PRs
/// have, the checked ones hidden or the only ones shown.
struct PullRequestFilterMenu: View {
    let session: RepoSession
    let listing: PullRequestListing

    var body: some View {
        Menu {
            Toggle(String(localized: "Hide Drafts", bundle: .module), isOn: filter(\.hidesDrafts))
            Toggle(String(localized: "Hide Bots", bundle: .module), isOn: filter(\.hidesBots))
            Toggle(
                String(localized: "Only Review Requests", bundle: .module),
                isOn: filter(\.onlyReviewRequests))
            Divider()
            checked(String(localized: "Authors", bundle: .module), listing.authors, \.authors)
            checked(String(localized: "Labels", bundle: .module), listing.labels, \.labels)
            Divider()
            Toggle(
                String(localized: "Show Hidden", bundle: .module),
                isOn: Bindable(session).showsHiddenPullRequests)
            Button(String(localized: "Show All", bundle: .module)) {
                session.clearPullRequestFilters()
            }
            .disabled(session.pullRequestFilter.isEmpty)
        } label: {
            Image(
                systemName: session.pullRequestFilter.isEmpty
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Filter pull requests", bundle: .module))
    }

    /// Show Only Checked with one checked is how the reader keeps a single label.
    private func checked(
        _ title: String, _ values: [String],
        _ keyPath: WritableKeyPath<PullRequestFilter, PullRequestFilter.Checked>
    ) -> some View {
        Menu(title) {
            Picker(selection: mode(keyPath)) {
                Text("Hide Checked", bundle: .module).tag(PullRequestFilter.Checked.Mode.hide)
                Text("Show Only Checked", bundle: .module)
                    .tag(PullRequestFilter.Checked.Mode.showOnly)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            Divider()
            ForEach(values, id: \.self) { value in
                Toggle(value, isOn: isChecked(value, keyPath))
            }
            Divider()
            Button(String(localized: "Check All", bundle: .module)) {
                session.pullRequestFilter[keyPath: keyPath].values = Set(values)
            }
            Button(String(localized: "Uncheck All", bundle: .module)) {
                session.pullRequestFilter[keyPath: keyPath].values = []
            }
        }
        .disabled(values.isEmpty)
    }

    private func filter(_ keyPath: WritableKeyPath<PullRequestFilter, Bool>) -> Binding<Bool> {
        Binding(
            get: { session.pullRequestFilter[keyPath: keyPath] },
            set: { session.pullRequestFilter[keyPath: keyPath] = $0 })
    }

    private func mode(_ keyPath: WritableKeyPath<PullRequestFilter, PullRequestFilter.Checked>)
        -> Binding<PullRequestFilter.Checked.Mode>
    {
        Binding(
            get: { session.pullRequestFilter[keyPath: keyPath].mode },
            set: { session.pullRequestFilter[keyPath: keyPath].mode = $0 })
    }

    private func isChecked(
        _ value: String, _ keyPath: WritableKeyPath<PullRequestFilter, PullRequestFilter.Checked>
    ) -> Binding<Bool> {
        Binding(
            get: { session.pullRequestFilter[keyPath: keyPath].values.contains(value) },
            set: { session.setChecked(value, $0, in: keyPath) })
    }
}
