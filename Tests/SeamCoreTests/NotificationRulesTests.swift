import Foundation
import GitKit
import Testing

@testable import SeamCore

/// What's news between two snapshots (SPEC §7.10).
@Suite(.timeLimit(.minutes(1))) struct NotificationRulesTests {
    private let start = Date(timeIntervalSince1970: 1_792_756_800)

    private func pullRequest(
        state: PullRequest.State = .open, checks: PullRequest.Checks = .init(),
        mergeState: PullRequest.MergeState? = nil
    ) -> PullRequest {
        PullRequest(
            number: 12, title: "Count the lines", url: "u", state: state, head: "feature",
            headOwner: "o", headCommit: "abc", base: "main", checks: checks,
            mergeState: mergeState, updated: start)
    }

    private func comment(_ id: String, by author: String = "claude") -> ThreadComment {
        ThreadComment(id: id, author: author, body: "Done in a.txt:3.", date: start)
    }

    private func events(
        _ before: NotificationSnapshot.Worktree, _ after: NotificationSnapshot.Worktree
    ) -> [NotificationEvent.What] {
        NotificationRules.events(
            from: NotificationSnapshot(worktrees: ["/w": before]),
            to: NotificationSnapshot(worktrees: ["/w": after])
        ).map(\.what)
    }

    @Test func nothingIsNewsTheFirstTimeAWorktreeIsSeen() {
        let now = NotificationSnapshot(worktrees: [
            "/w": .init(awaiting: ["t1": comment("c1")], pullRequest: pullRequest())
        ])
        #expect(NotificationRules.events(from: NotificationSnapshot(), to: now).isEmpty)
    }

    @Test func anAgentsNewWordInAThreadIsNewsOnce() {
        let before = NotificationSnapshot.Worktree(awaiting: ["t1": comment("c1")])
        let after = NotificationSnapshot.Worktree(awaiting: [
            "t1": comment("c1"), "t2": comment("c2"),
        ])
        #expect(
            events(before, after)
                == [.agent(thread: "t2", author: "claude", body: "Done in a.txt:3.")])
        #expect(events(after, after).isEmpty)
        var unread = before
        unread.threadsRead = false
        #expect(events(unread, after).isEmpty, "the first read is a state, not news")
    }

    @Test func checksFinishingIsNewsAsFailedOrPassed() {
        let running = pullRequest(checks: .init(passed: 1, pending: 2))
        let failed = pullRequest(checks: .init(passed: 2, failed: 1))
        let passed = pullRequest(checks: .init(passed: 3))
        #expect(
            events(.init(pullRequest: running), .init(pullRequest: failed)) == [
                .checksFailed(failed)
            ])
        #expect(
            events(.init(pullRequest: running), .init(pullRequest: passed)) == [
                .checksPassed(passed)
            ])
        #expect(events(.init(pullRequest: passed), .init(pullRequest: passed)).isEmpty)
    }

    @Test func newReviewsAndCommentsByOthersAreNewsOnceTheDiscussionWasRead() {
        let comment = GitHubConversationItem(
            id: 5, author: "octocat", body: "Looks close.", created: start, url: "c5")
        let approval = GitHubConversationItem(
            id: 5, kind: .approved, author: "hubot", body: "", created: start + 60, url: "r5")
        let line = NotificationEvent.Comment(author: "octocat", body: "Why?", thread: "gh-7")
        let unread = NotificationSnapshot.Worktree(pullRequest: pullRequest())
        let read = NotificationSnapshot.Worktree(pullRequest: pullRequest(), discussionRead: true)
        let after = NotificationSnapshot.Worktree(
            pullRequest: pullRequest(), discussionRead: true, gitHubComments: [7: line],
            conversation: [comment, approval])

        #expect(events(unread, after).isEmpty, "the first read is a state, not news")
        #expect(
            events(read, after)
                == [
                    .review(pullRequest(), approval),
                    .comments(
                        pullRequest(),
                        [.init(author: "octocat", body: "Looks close."), line]),
                ])
        #expect(events(after, after).isEmpty)
    }

    @Test func becomingReadyToMergeAndMergingAreNews() {
        let blocked = pullRequest(mergeState: .blocked)
        let ready = pullRequest(mergeState: .clean)
        let merged = pullRequest(state: .merged, mergeState: .clean)
        #expect(
            events(.init(pullRequest: blocked), .init(pullRequest: ready)) == [.readyToMerge(ready)]
        )
        #expect(events(.init(pullRequest: ready), .init(pullRequest: ready)).isEmpty)
        #expect(events(.init(pullRequest: ready), .init(pullRequest: merged)) == [.merged(merged)])
    }

    @Test func anotherPullRequestOnTheBranchIsNoNews() {
        var other = pullRequest(state: .merged)
        other.number = 13
        #expect(events(.init(pullRequest: pullRequest()), .init(pullRequest: other)).isEmpty)
    }
}
