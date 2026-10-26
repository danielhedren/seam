import AppKit
import DiffModel
import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import Synchronization
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct RepoSessionViewTests {
    @Test func openInEditorPassesTheWorktreePathAndReadingLine() async throws {
        let repo = try await FixtureRepo()
        try repo.write("dir with space/it's.txt", "one\ntwo\n")
        let launcher = FakeLauncher()
        var services = services(repo.git)
        services.launcher = launcher
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        await session.settled()
        try showDiff(session)

        session.openInEditor(EditorCommand(template: "ed +{line} {path}"))

        let path = repo.main.appending(path: "dir with space/it's.txt").path
        #expect(await launcher.next() == "ed +1 " + EditorCommand.quoted(path))
    }

    @Test func aFailingEditorShowsItsMessageAsABanner() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        let launcher = FakeLauncher()
        await launcher.fail(with: "zed: command not found")
        var services = services(repo.git)
        services.launcher = launcher
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        await session.settled()
        try showDiff(session)

        session.openInEditor()
        _ = await launcher.next()
        let review = try #require(session.selected)
        await until { review.problem != nil }

        #expect(review.problem == .editorFailed("zed: command not found"))
    }

    @Test func fileActionsCopyPathsAndFollowTheFilesState() async throws {
        let repo = try await FixtureRepo()
        try repo.write("dir/a.txt", "a\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()

        session.copyPath("dir/a.txt", relative: true)
        #expect(session.platform?.copied.last == "dir/a.txt")
        session.copyPath("dir/a.txt", relative: false)
        #expect(session.platform?.copied.last == repo.main.appending(path: "dir/a.txt").path)

        let titles = {
            FileActions.actions(for: "dir/a.txt", in: session).flatMap { $0.map(\.title) }
        }
        #expect(titles().contains("Mark as Viewed"))
        session.toggleViewed("dir/a.txt", advance: false)
        #expect(titles().contains("Mark as Not Viewed"))
        #expect(titles().contains("Expand File"))
        session.toggleCollapsed("dir/a.txt")
        #expect(titles().contains("Collapse File"))
    }

    @Test func aQuerySetBeforeTheFindBarExistsStillSearches() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "alpha\nbeta\nalpha\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        var totals: [Int] = []
        try showDiff(session).onSearchResult = { _, total in totals.append(total) }

        session.find.query = "alpha"

        #expect(totals.last == 2)
    }
}
