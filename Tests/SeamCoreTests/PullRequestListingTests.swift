import Foundation
import GitKit
import Testing

@testable import SeamCore

/// The pull request list's rows (SPEC §7.2.2).
@Suite(.timeLimit(.minutes(1))) struct PullRequestListingTests {
    private func pullRequest(
        _ number: Int, by author: String = "anna", updated: Int = 0, draft: Bool = false,
        bot: Bool = false, labels: [String] = [], state: PullRequest.State = .open
    ) -> PullRequest {
        PullRequest(
            number: number, title: "PR \(number)", url: "u\(number)", state: state,
            isDraft: draft, head: "b\(number)", headOwner: "o", headCommit: "c\(number)",
            base: "main", updated: Date(timeIntervalSince1970: Double(updated)), author: author,
            authorIsBot: bot, labels: labels)
    }

    private func listed(
        _ open: [PullRequest], viewer: String? = "me", requests: Set<Int> = [],
        checkedOut: Set<Int> = [], filter: PullRequestFilter = .init(), showsHidden: Bool = false
    ) -> PullRequestListing {
        PullRequestListing(
            open: open, viewer: viewer, reviewRequests: requests, checkedOut: checkedOut,
            filter: filter, showsHidden: showsHidden)
    }

    @Test func othersOpenPullRequestsAreListedNewestFirst() {
        let listing = listed([
            pullRequest(1, updated: 10), pullRequest(2, updated: 30), pullRequest(3, updated: 20),
        ])
        #expect(listing.rows.map(\.id) == [2, 3, 1])
        #expect(listing.matching == 3)
        #expect(listing.hidden == 0)
    }

    @Test func theReadersOwnAndCheckedOutOnesAreNeverListed() {
        let listing = listed(
            [pullRequest(1, by: "Me"), pullRequest(2), pullRequest(3)], checkedOut: [3])
        #expect(listing.rows.map(\.id) == [2])
        #expect(
            listing.hidden == 0, "they aren't hidden by a filter, so Show Hidden can't list them")
    }

    @Test func reviewsAskedOfTheReaderComeFirst() {
        let listing = listed(
            [pullRequest(1, updated: 10), pullRequest(2, updated: 30)], requests: [1])
        #expect(listing.rows.map(\.id) == [1, 2])
        #expect(listing.rows.map(\.isReviewRequested) == [true, false])
    }

    @Test func eachFilterHidesWhatItSays() {
        let open = [
            pullRequest(1, draft: true), pullRequest(2, by: "renovate[bot]"),
            pullRequest(3, by: "app/dependabot", bot: true), pullRequest(4, by: "bob"),
            pullRequest(5, labels: ["wip", "ui"]), pullRequest(6), pullRequest(7),
        ]
        func shown(_ filter: PullRequestFilter, requests: Set<Int> = []) -> [Int] {
            listed(open, requests: requests, filter: filter).rows.map(\.id).sorted()
        }
        #expect(shown(.init(hidesDrafts: true)) == [2, 3, 4, 5, 6, 7])
        #expect(shown(.init(hidesBots: true)) == [1, 4, 5, 6, 7])
        #expect(shown(.init(onlyReviewRequests: true), requests: [6]) == [6])
        #expect(shown(.init(authors: .init(.hide, ["bob"]))) == [1, 2, 3, 5, 6, 7])
        #expect(shown(.init(labels: .init(.hide, ["ui"]))) == [1, 2, 3, 4, 6, 7])
        #expect(shown(.init(authors: .init(.showOnly, ["bob"]))) == [4])
        #expect(shown(.init(labels: .init(.showOnly, ["ui"]))) == [5])
        #expect(shown(.init(labels: .init(.showOnly, []))) == [], "nothing checked yet")
        #expect(shown(.init(hiddenNumbers: [7])) == [1, 2, 3, 4, 5, 6])
        #expect(listed(open, filter: .init(hidesBots: true)).hidden == 2)
    }

    /// Review requests or involving me, not requests that also involve me.
    @Test func theShowOnlySwitchesAddUp() {
        func shown(_ filter: PullRequestFilter) -> [Int] {
            PullRequestListing(
                open: [pullRequest(1), pullRequest(2), pullRequest(3)], viewer: "me",
                reviewRequests: [3], checkedOut: [], filter: filter, involving: [1]
            ).rows.map(\.id).sorted()
        }
        #expect(shown(.init(onlyInvolvingMe: true)) == [1])
        #expect(shown(.init(onlyReviewRequests: true)) == [3])
        #expect(shown(.init(onlyReviewRequests: true, onlyInvolvingMe: true)) == [1, 3])
    }

    @Test func showHiddenListsWhatTheFiltersHideAfterTheRest() {
        let listing = listed(
            [pullRequest(1, updated: 30, draft: true), pullRequest(2, updated: 10)],
            filter: .init(hidesDrafts: true), showsHidden: true)
        #expect(listing.rows.map(\.id) == [2, 1])
        #expect(listing.rows.map(\.isHidden) == [false, true])
        #expect(listing.matching == 1)
    }

    @Test func pastTheLimitTheMostRecentlyUpdatedAreListed() {
        let open = (1...230).map { pullRequest($0, updated: $0) }
        let listing = listed(open)
        #expect(listing.rows.count == 100)
        #expect(listing.rows.first?.id == 230)
        #expect(listing.rows.last?.id == 131)
        #expect(listing.isCapped)
        #expect(listing.matching == 230)
    }

    @Test func theFilterMenuOffersEveryAuthorAndLabelAndKeepsHiddenOnesThatLeft() {
        let listing = listed(
            [pullRequest(1, by: "bob", labels: ["ui"]), pullRequest(2, by: "anna")],
            filter: .init(authors: .init(.hide, ["carl"]), labels: .init(.showOnly, ["old"])))
        #expect(listing.authors == ["anna", "bob", "carl"])
        #expect(listing.labels == ["old", "ui"])
    }

    @Test func aFilterSavedBeforeAFieldExistedKeepsItsDefault() throws {
        let saved = Data(#"{"hidesDrafts":true,"hiddenAuthors":["bob"]}"#.utf8)
        let filter = try JSONDecoder().decode(PullRequestFilter.self, from: saved)
        #expect(filter == PullRequestFilter(hidesDrafts: true, authors: .init(.hide, ["bob"])))
        let again = try JSONDecoder().decode(
            PullRequestFilter.self, from: JSONEncoder().encode(filter))
        #expect(again == filter)
    }
}

/// News about the pull request list (SPEC §7.10).
@Suite(.timeLimit(.minutes(1))) struct ListedNotificationTests {
    private func pullRequest(_ number: Int) -> PullRequest {
        PullRequest(
            number: number, title: "PR \(number)", url: "u", state: .open, head: "b",
            headOwner: "o", headCommit: "c", base: "main", updated: .distantPast, author: "anna")
    }

    private func listed(_ shown: [Int], known: [Int]? = nil, requests: Set<Int> = [])
        -> NotificationSnapshot.Listed
    {
        NotificationSnapshot.Listed(
            known: Set(known ?? shown),
            shown: Dictionary(uniqueKeysWithValues: shown.map { ($0, pullRequest($0)) }),
            reviewRequests: requests)
    }

    private func events(
        _ before: NotificationSnapshot.Listed?, _ after: NotificationSnapshot.Listed?
    ) -> [NotificationEvent.What] {
        NotificationRules.events(
            from: NotificationSnapshot(listed: before), to: NotificationSnapshot(listed: after)
        ).map(\.what)
    }

    @Test func theFirstReadIsAState() {
        #expect(events(nil, listed([1], requests: [1])).isEmpty)
    }

    @Test func aNewPullRequestTheListShowsIsNewsOnce() {
        let before = listed([1])
        let after = listed([1, 2])
        #expect(events(before, after) == [.newPullRequest(pullRequest(2))])
        #expect(events(after, after).isEmpty)
    }

    @Test func aReviewAskedOfTheReaderIsNewsAndANewOneSaysOnlyThat() {
        #expect(
            events(listed([1]), listed([1], requests: [1])) == [.reviewRequested(pullRequest(1))])
        #expect(
            events(listed([1]), listed([1, 2], requests: [2])) == [.reviewRequested(pullRequest(2))]
        )
    }

    @Test func aPushToAPullRequestBeingReviewedIsNewsOncePerHead() {
        var pushed = pullRequest(1)
        pushed.headCommit = "c2"
        var again = pushed
        again.headCommit = "c3"
        let before = listed([1])
        var after = listed([1])
        after.newCommits = [1: pushed]
        var later = after
        later.newCommits = [1: again]

        #expect(events(before, after) == [.newCommits(pushed)])
        #expect(events(after, after).isEmpty)
        #expect(events(after, later) == [.newCommits(again)])
    }

    @Test func whatTheFiltersHideIsNoNewsEvenWhenAFilterIsTurnedOff() {
        // 2 is open but hidden: known, not shown.
        let before = listed([1], known: [1, 2])
        #expect(events(before, listed([1], known: [1, 2, 3])).isEmpty, "3 is new but hidden")
        #expect(events(before, listed([1, 2], known: [1, 2])).isEmpty, "2 was there all along")
    }
}
