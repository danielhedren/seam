import Foundation
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

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

/// SPEC §7.1 and §13: one window per repo, whichever window a `seam` call or a drop reaches.
@Suite(.timeLimit(.minutes(1)))
struct OpenRouteTests {
    @Test(
        arguments: [
            ("/r", "/r", Set<String>(), OpenRoute.here),
            ("/r", nil, [], .becomeRepo),
            ("/r", nil, ["/r"], .repoWindow(closesWelcome: true)),
            ("/r", "/other", ["/other"], .repoWindow(closesWelcome: false)),
            ("/r", "/other", ["/other", "/r"], .repoWindow(closesWelcome: false)),
        ] as [(String, String?, Set<String>, OpenRoute)])
    func anOpenGoesToTheRepositorysOwnWindow(
        repo: String, shown: String?, open: Set<String>, route: OpenRoute
    ) {
        #expect(OpenRoute.decide(repo: repo, shown: shown, open: open) == route)
    }
}
