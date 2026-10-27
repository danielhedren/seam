import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct SettingsTests {
    @Test func valuesPersistInTheirDefaultsDomain() throws {
        let defaults = Scratch.defaults("seam-settings")
        let settings = AppSettings(defaults: defaults)
        settings.defaultBase = "origin/develop"
        settings.contextLines = 7
        settings.whitespace = .ignoreAll
        settings.ignoredRefs = ["origin/bots/**"]
        #expect(settings.notifications == Set(NotificationKind.allCases), "all on until turned off")
        settings.notifications = [.agent, .readyToMerge]
        settings.notifiesInFront = true

        let reread = AppSettings(defaults: defaults)

        #expect(reread.detection.defaultBase == "origin/develop")
        #expect(reread.detection.ignoredRefs == [Glob("origin/bots/**")])
        #expect(reread.diffOptions.contextLines == 7)
        #expect(reread.diffOptions.whitespace == .ignoreAll)
        #expect(reread.notifications == [.agent, .readyToMerge])
        #expect(reread.notifiesInFront)
    }

    @Test func contextLinesAndEditorConfigReachTheReview() async throws {
        let repo = try await FixtureRepo()
        try await repo.commit(
            "a.cs", (1...20).map { "\tline \($0)" }.joined(separator: "\n") + "\n", "a")
        try repo.write(".editorconfig", "[*.cs]\nindent_size = 2\n")
        try repo.write(
            "a.cs",
            (1...20).map { $0 == 10 ? "\tten" : "\tline \($0)" }.joined(separator: "\n") + "\n")
        let services = services(repo.git)
        services.settings.contextLines = 1
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        session.setBaseOverride("refs/heads/main")
        await session.settled()

        let content = try #require(session.selected?.content)
        let hunk = try #require(
            content.review.files.first { $0.diff.path == "a.cs" }?.diff.hunks.first)
        #expect(hunk.lines.count == 4)
        #expect(content.tabWidths["a.cs"] == 2)
    }
}
