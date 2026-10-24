import Foundation
import TestSupport
import Testing

@testable import Features

@MainActor
@Suite(.timeLimit(.minutes(1))) struct WorkspaceTests {
    /// A throwaway domain: the real one holds the user's workspace.
    private func scratchDefaults() throws -> UserDefaults {
        Scratch.defaults("seam-workspace")
    }

    @Test func reposOpenedStayInOrderAndComeBackNextLaunch() throws {
        let defaults = try scratchDefaults()
        let requests = OpenRequests(defaults: defaults)
        requests.windowOpened("/r/b")
        requests.windowOpened("/r/a")
        requests.windowOpened("/r/b")

        #expect(requests.workspace == ["/r/b", "/r/a"])
        #expect(OpenRequests(defaults: defaults).workspace == ["/r/b", "/r/a"])
    }

    @Test func closingAWindowTakesItsRepoOutButQuittingDoesNot() throws {
        let defaults = try scratchDefaults()
        let requests = OpenRequests(defaults: defaults)
        for repo in ["/r/a", "/r/b", "/r/c"] { requests.windowOpened(repo) }
        requests.windowClosed("/r/b")
        requests.willTerminate()
        requests.windowClosed("/r/a")
        requests.windowClosed("/r/c")

        #expect(OpenRequests(defaults: defaults).workspace == ["/r/a", "/r/c"])
        #expect(requests.openWindows.isEmpty)
    }
}

@Suite(.timeLimit(.minutes(1))) struct LaunchArgumentTests {
    @Test(
        arguments: [
            (["Seam", "/repo"], "/repo"),
            (["Seam", "-NSDocumentRevisionsDebugMode", "YES", "/repo"], "/repo"),
            (["Seam", "-NSDocumentRevisionsDebugMode", "YES"], nil),
            (
                [
                    "Seam", "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows",
                    "NO", "/r",
                ], "/r"
            ),
            (["Seam"], nil),
        ] as [([String], String?)])
    func defaultsPairsAreNotTakenForAPath(arguments: [String], expected: String?) {
        #expect(WelcomeView.launchPath(arguments) == expected)
    }
}
