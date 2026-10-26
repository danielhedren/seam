import ReviewTestSupport
import TestSupport
import Testing

@testable import ReviewModel

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BannerTests {
    @Test func aFailedEditorLaunchCanBeDismissedButADiffProblemCannot() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "x\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)

        review.report(.editorFailed("zed: command not found"))
        review.dismissNotice()
        #expect(review.problem == nil)

        review.report(.gitFailed("fatal: bad revision"))
        review.dismissNotice()
        #expect(review.problem == .gitFailed("fatal: bad revision"))
    }
}
