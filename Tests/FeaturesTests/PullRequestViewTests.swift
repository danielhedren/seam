import Foundation
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
}
