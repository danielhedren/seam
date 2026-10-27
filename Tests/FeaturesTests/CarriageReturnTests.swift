import DiffModel
import Foundation
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import DiffView
@testable import Features
@testable import ReviewModel

/// A CRLF file's lines look like any other's until View › Show Carriage Returns (SPEC §7.4).
@MainActor @Suite(.timeLimit(.minutes(1))) struct CarriageReturnTests {
    @Test func carriageReturnsShowOnlyWhenTheViewMenuAsks() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\r\ntwo\r\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        let pane = CardWindow(session: session, review: review)
        func drawn() -> [String]? {
            CardWindow.find(DiffCanvasView.self, in: pane.window.contentView)?.layout.rows
                .compactMap { row in
                    if case .line(_, let line) = row { return line.text }
                    return nil
                }
        }
        #expect(await pane.wait { drawn() == ["one", "two"] })

        let show = try command("carriage-returns")
        show.run(session)
        #expect(session.settings.showsCarriageReturns)
        #expect(await pane.wait { drawn() == ["one␍", "two␍"] })
        show.run(session)
        #expect(await pane.wait { drawn() == ["one", "two"] })
        session.close()
    }
}
