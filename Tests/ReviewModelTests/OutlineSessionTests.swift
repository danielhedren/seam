import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import DiffModel
@testable import ReviewModel

/// A file's outline, opened from the menu and read in the diff (SPEC §7.4).
@MainActor @Suite(.timeLimit(.minutes(1))) struct OutlineSessionTests {
    private func session() async throws -> (RepoSession, WorktreeReview) {
        let repo = try await FixtureRepo()
        try await repo.commit(
            "order.ts", "class Order {\n  total() {\n    return 1;\n  }\n}\n", "Add order")
        try await repo.run("push", "-q", "origin", "main")
        try repo.write("order.ts", "class Order {\n  total() {\n    return 2;\n  }\n}\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        await review.loaded()
        await review.highlighted()
        return (session, review)
    }

    private func outlineRows(_ review: WorktreeReview) -> [OutlineEntry] {
        guard let content = review.content else { return [] }
        return DiffRowBuilder.rows(for: content).compactMap {
            if case .outline(_, let entry) = $0 { entry } else { nil }
        }
    }

    @Test func aFilesOutlineNamesTheDefinitionItsChangeTouchesUnderItsHeader() async throws {
        let (session, review) = try await session()
        #expect(outlineRows(review).isEmpty, "off until asked for")
        review.currentFile = "order.ts"
        let command = try #require(CommandCatalog.byID["outline"])

        command.run(session)

        let total = OutlineEntry(change: .body, path: ["Order", "total"], line: 3)
        #expect(outlineRows(review) == [total])
        #expect(DiffRowBuilder.outlineLabel(total) == "~ Order › total  body")
        #expect(command.title(for: session) == "Hide Outline of This File")
        session.close()
    }

    @Test func aCollapsedFileKeepsItsOutlineAndARowOpensIt() async throws {
        let (session, review) = try await session()
        session.settings.showsOutlines = true
        session.toggleCollapsed("order.ts")
        #expect(review.collapsed == ["order.ts"])
        let entries = outlineRows(review)
        #expect(entries.count == 1)

        session.openOutline("order.ts", try #require(entries.first))

        #expect(review.collapsed.isEmpty)
        session.close()
    }
}
