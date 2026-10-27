import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct PullRequestViewTests {
    /// GitHub's octicons, bundled: every marker shows a different set of shapes.
    @Test func everyMarkerDrawsItsOwnGitHubIcons() throws {
        for icon in Octicon.allCases {
            let image = try #require(icon.nsImage, "\(icon)")
            #expect(image.isValid && image.isTemplate)
        }
        let markers = [
            fakePullRequest(1, draft: true), fakePullRequest(2),
            fakePullRequest(3, review: .commented), fakePullRequest(4, review: .changesRequested),
            fakePullRequest(5, review: .approved), fakePullRequest(6, state: .merged),
            fakePullRequest(7, state: .closed),
        ]
        let shapes = markers.map {
            [PullRequestBadge.stateIcon($0.marker), PullRequestBadge.reviewIcon($0)?.icon]
        }
        #expect(Set(shapes).count == markers.count)
    }

    @Test func aWorktreeRowsMenuOpensAndCopiesItsPullRequest() async throws {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("a.txt", "a\n", "Add a", in: feature)
        try await repo.run("remote", "set-url", "origin", "https://github.com/owner/app.git")
        let github = FakeGitHub()
        github.answer(open: [fakePullRequest(12)])
        let session = RepoSession(
            directory: repo.main,
            services: services(repo.git, github: GitHubAccount(client: github)))
        await session.open()
        await session.settled()
        let review = try #require(session.reviews.first { $0.id == feature.path })
        await until { review.pullRequest != nil }

        let actions = RowActions.actions(for: review, in: session)
        #expect(
            actions.last?.map(\.title) == ["Open Pull Request in Browser", "Copy Pull Request URL"])
        session.close()
    }

    /// Threads shows the conversation, and a later read redraws it as a fresh list
    /// would; with pull requests off it's gone.
    @Test func threadsShowsTheConversationAndFollowsANewRead() async throws {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("a.txt", "a\n", "Add a", in: feature)
        try await repo.run("remote", "set-url", "origin", "https://github.com/owner/app.git")
        let github = FakeGitHub()
        let created = Date(timeIntervalSince1970: 1_792_756_800)
        let comment = GitHubConversationItem(
            id: 5, author: "octocat", body: "Looks close.", created: created, url: "c5")
        let approval = GitHubConversationItem(
            id: 9, kind: .approved, author: "hubot", body: "", created: created + 60, url: "r9")
        github.answer(open: [fakePullRequest(12)])
        github.answer(threads: [], conversation: [comment], for: 12)
        let session = RepoSession(
            directory: repo.main,
            services: services(repo.git, github: GitHubAccount(client: github)))
        await session.open()
        session.select(feature.path)
        await session.settled()
        let review = try #require(session.selected)
        await until { review.conversation != nil }
        let panel = ThreadsWindow(session: session, review: review)
        await panel.settle()
        let empty = ThreadsWindow(session: session, review: try #require(session.reviews.first))
        await empty.settle()
        let first = try panel.png()
        #expect(first != (try empty.png()), "the conversation shows")

        github.answer(threads: [], conversation: [comment, approval], for: 12)
        session.reload()
        await until { review.conversation?.items.count == 2 }
        await panel.settle()
        let fresh = ThreadsWindow(session: session, review: review)
        await fresh.settle()
        #expect(try panel.png() == fresh.png())
        #expect(try panel.png() != first)

        // Picking it opens its card above the first file, every entry in it.
        let card = CardWindow(session: session, review: review)
        await card.settle()
        await session.pick(thread: WorktreeReview.conversationID)
        #expect(await card.wait { card.host != nil })
        #expect(
            session.diffUpdate(for: review, after: nil)?.content.preamble.first?.id
                == WorktreeReview.conversationID)
        let height = try #require(card.host).frame.height
        session.closeThread()
        #expect(await card.wait { card.host == nil })
        #expect(height > 100, "both entries show")
        session.close()
    }
}
