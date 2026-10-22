import AppKit
import SeamCore
import SwiftUI
import TestSupport
import Testing

@testable import Features

/// SPEC §7.1: a window keeps its frame, titlebar and toolbar while its repo opens. Windows here
/// are real but never ordered on screen.
@MainActor
@Suite struct WindowLayoutTests {
    /// What moves the content when it changes: the frame, the titlebar's height and the toolbar.
    private struct Chrome: Equatable {
        var frame: NSRect
        var contentLayout: NSRect
        var toolbar: [String]

        @MainActor init(_ window: NSWindow) {
            frame = window.frame
            contentLayout = window.contentLayoutRect
            toolbar = window.toolbar?.items.map { $0.label.isEmpty ? "-" : $0.label } ?? []
        }
    }

    /// A window that's never shown doesn't run the view's `.task`, so the test opens the repo.
    @Test func aRepoWindowKeepsItsChromeWhileTheRepoOpens() async throws {
        let repo = try await FixtureRepo()
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        let window = try window(showing: RepoWindow(session: session))
        settleLayout()
        let opening = Chrome(window)

        await session.open()
        await session.settled()
        settleLayout()

        #expect(session.selected != nil)
        #expect(Chrome(window) == opening)
        #expect(opening.toolbar.contains("Reload"))
        window.close()
    }

    private func window(showing view: some View) throws -> NSWindow {
        let host = NSHostingController(
            rootView: view.environment(OpenRequests(defaults: try scratchDefaults())))
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = plainWindow(NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentViewController = host
        window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: false)
        return window
    }

    /// Titled like a SwiftUI window, so the titlebar and toolbar take part in the layout.
    private func plainWindow(_ frame: NSRect = NSRect(x: 0, y: 0, width: 900, height: 600))
        -> NSWindow
    {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrame(frame, display: false)
        return window
    }

    private func scratchDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "seam-windows-\(UUID().uuidString)"))
    }
}

/// Lets SwiftUI and AppKit finish the layout and toolbar updates they schedule.
@MainActor
private func settleLayout() {
    for _ in 0..<20 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
}
