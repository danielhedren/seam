import Foundation
import Testing

@testable import Features

@MainActor
@Suite struct WorkspaceTests {
    /// A throwaway domain: the real one holds the user's workspace.
    private func scratchDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "seam-workspace-\(UUID().uuidString)"))
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
