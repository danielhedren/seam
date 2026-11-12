import DiffView
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct HistoryViewTests {
    private func session() async throws -> (RepoSession, DiffScrollView) {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numberedLines(1...200))
        try repo.write("b.txt", numberedLines(1...200))
        let (session, _) = try await openedSession(repo)
        return (session, try showDiff(session))
    }

    @Test func backReturnsFromAFilePickedInTheListAndForwardGoesThereAgain() async throws {
        let (session, view) = try await session()
        view.scroll(toLine: 120, inFile: "a.txt", oldSide: false)
        let start = try #require(view.anchor)
        #expect(start.path == "a.txt")
        #expect(!session.canGoBack)

        session.diff.scroll(toFile: "b.txt")
        #expect(view.anchor?.path == "b.txt")
        try command("back").run(session)
        #expect(view.anchor == start)
        #expect(session.canGoForward && !session.canGoBack)

        try command("forward").run(session)
        #expect(view.anchor?.path == "b.txt")
        #expect(session.selected?.currentFile == "b.txt")
    }

    @Test func backReturnsFromAFindMatchAndAThreadsLines() async throws {
        let (session, view) = try await session()
        let start = try #require(view.anchor)

        session.find.query = "150"
        let match = try #require(view.anchor)
        #expect(match != start)
        session.diff.scroll(toLine: 180, inFile: "b.txt", side: .new)
        #expect(view.anchor?.path == "b.txt")

        try command("back").run(session)
        // Scrolling lands on whole pixels, so only the line is compared.
        #expect(view.anchor?.path == "a.txt" && view.anchor?.line == match.line)
        try command("back").run(session)
        #expect(view.anchor == start)
    }

    @Test func backOpensACollapsedFileToShowThePlace() async throws {
        let (session, view) = try await session()
        view.scroll(toLine: 120, inFile: "a.txt", oldSide: false)
        session.diff.scroll(toFile: "b.txt")
        session.toggleCollapsed("a.txt")

        try command("back").run(session)
        #expect(session.selected?.collapsed.contains("a.txt") == false)
    }
}
