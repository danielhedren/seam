import GitKit
import ReviewModel
import SeamCore
import SwiftUI

/// Other people's open pull requests, under the worktrees (SPEC §7.2.2). Until they can be
/// reviewed here (M11), picking one opens it on GitHub.
struct PullRequestList: View {
    let session: RepoSession

    var body: some View {
        let listing = session.pullRequestListing
        List(selection: Binding<Int?>(get: { nil }, set: { $0.map(session.openListedPullRequest) }))
        {
            Section {
                ForEach(listing.rows) { row in
                    PullRequestListRow(row: row).tag(row.id)
                }
            } header: {
                HStack {
                    Text(Self.header(listing)).lineLimit(1)
                    Spacer(minLength: 4)
                    PullRequestFilterMenu(session: session, listing: listing)
                }
            }
        }
        .contextMenu(forSelectionType: Int.self) { numbers in
            if numbers.count == 1, let number = numbers.first,
                let row = listing.rows.first(where: { $0.id == number })
            {
                rowMenu(row.pullRequest)
            }
        }
        .overlay {
            if listing.rows.isEmpty {
                Text(Self.empty(listing)).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding()
            }
        }
    }

    @ViewBuilder private func rowMenu(_ pullRequest: PullRequest) -> some View {
        let number = pullRequest.number
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
        if !pullRequest.author.isEmpty {
            Button(
                String(localized: "Hide Pull Requests by \(pullRequest.author)", bundle: .module)
            ) {
                session.setHides(author: pullRequest.author, true)
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
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .opacity(row.isHidden ? 0.5 : 1)
        .help(
            pullRequest.labels.isEmpty
                ? pullRequest.title : pullRequest.labels.joined(separator: ", "))
    }
}

/// The list's filters (SPEC §7.2.2): the switches, then every author and label the open PRs
/// have, checked when hidden.
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
            Menu(String(localized: "Hidden Authors", bundle: .module)) {
                ForEach(listing.authors, id: \.self) { author in
                    Toggle(author, isOn: hides(author: author))
                }
            }
            .disabled(listing.authors.isEmpty)
            Menu(String(localized: "Hidden Labels", bundle: .module)) {
                ForEach(listing.labels, id: \.self) { label in
                    Toggle(label, isOn: hides(label: label))
                }
            }
            .disabled(listing.labels.isEmpty)
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

    private func filter(_ keyPath: WritableKeyPath<PullRequestFilter, Bool>) -> Binding<Bool> {
        Binding(
            get: { session.pullRequestFilter[keyPath: keyPath] },
            set: { session.pullRequestFilter[keyPath: keyPath] = $0 })
    }

    private func hides(author: String) -> Binding<Bool> {
        Binding(
            get: { session.pullRequestFilter.hiddenAuthors.contains(author) },
            set: { session.setHides(author: author, $0) })
    }

    private func hides(label: String) -> Binding<Bool> {
        Binding(
            get: { session.pullRequestFilter.hiddenLabels.contains(label) },
            set: { session.setHides(label: label, $0) })
    }
}
