import SeamCore
import Testing

/// Which notifications opening something in Seam answers (SPEC §7.10).
@Suite(.timeLimit(.minutes(1))) struct NotificationSubjectTests {
    private let ids = [
        "/repo|agent-t1", "/repo|agent-t2", "/repo|checks-12-abc", "/repo|review-r9",
        "/repo|comments-12", "/repo|ready-12", "/repo|closed-12", "/repo|pr-20",
        "/repo|pr-20-commits", "/repo|pr-200",
        "/repo/wt|agent-t1", "/repo/wt|checks-13-def",
    ]

    @Test func anOpenedThreadCoversOnlyItsOwnAnswer() {
        let subject = NotificationSubject.thread(worktree: "/repo", id: "t1")
        #expect(ids.filter(subject.covers) == ["/repo|agent-t1"])
    }

    @Test func aSelectedWorktreeCoversItsPullRequestsNewsOnly() {
        let subject = NotificationSubject.worktree("/repo")
        #expect(
            ids.filter(subject.covers) == [
                "/repo|checks-12-abc", "/repo|review-r9", "/repo|comments-12", "/repo|ready-12",
                "/repo|closed-12",
            ])
        let other = NotificationSubject.worktree("/repo/wt")
        #expect(ids.filter(other.covers) == ["/repo/wt|checks-13-def"])
    }

    @Test func anOpenedListedPullRequestCoversItsNews() {
        let subject = NotificationSubject.pullRequest(repo: "/repo", number: 20)
        #expect(ids.filter(subject.covers) == ["/repo|pr-20", "/repo|pr-20-commits"])
        let other = NotificationSubject.pullRequest(repo: "/repo", number: 2)
        #expect(ids.filter(other.covers) == [])
    }
}
