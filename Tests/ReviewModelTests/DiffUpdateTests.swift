import DiffModel
import Foundation
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

/// What the diff is given and where it scrolls (SPEC §7.4, §8.6), decided without a window.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DiffUpdateTests {
    @Test func aReloadKeepsThePlaceAnotherRangeStartsAtTheTopAndASwitchReturnsToTheSavedLine()
        async throws
    {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("f.txt", "f\n", "f1", in: feature)
        try repo.write("a.txt", "one\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let main = try #require(session.selected)
        #expect(session.diffUpdate(for: main, after: nil)?.position == .top)
        let shown = session.diffShown(for: main)

        try repo.write("a.txt", "two\n")
        await session.apply(RepoChange(worktrees: [repo.main.path]))
        await session.settled()
        #expect(session.diffShown(for: main) != shown, "the reload is new content")
        #expect(session.diffUpdate(for: main, after: shown)?.position == .keep)

        session.setScope(.uncommitted)
        await main.loaded()
        #expect(session.diffUpdate(for: main, after: shown)?.position == .top)

        let anchor = ScrollAnchor(path: "f.txt", line: 1, offset: 0)
        let other = try #require(session.reviews.first { $0.id == feature.path })
        other.savedAnchor = anchor
        session.select(feature.path)
        await other.loaded()
        #expect(session.diffUpdate(for: other, after: shown)?.position == .anchor(anchor))
        session.close()
    }

    /// An open thread shows in the diff even when it's resolved and resolved ones are hidden.
    @Test func anOpenResolvedThreadIsDrawnWhileResolvedOnesAreHidden() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let (session, review, _) = await threadSession(repo)
        let reviewed = try #require(review)
        session.draft = ThreadDraft(
            worktree: reviewed.id,
            anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await session.post("Why one?")
        let id = try #require(session.selectedThreadID)
        await session.setResolved(true, thread: id)
        #expect(reviewed.content?.threads["a.txt"]?.contains { $0.id == id } != true)

        session.openThread(id)
        let content = try #require(session.diffUpdate(for: reviewed, after: nil)?.content)
        #expect(content.openThread == id)
        #expect(content.threads["a.txt"]?.map(\.id) == [id])
        #expect(content.resolvedMarks["a.txt"]?.contains { $0.id == id } != true)
        session.close()
    }
}
