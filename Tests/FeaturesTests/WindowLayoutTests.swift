import AppKit
import SeamCore
import SwiftUI
import TestSupport
import Testing

@testable import Features

/// SPEC §7.1: a window keeps its frame, titlebar and toolbar while its repo opens, and a repo's
/// window comes back in its own frame. Windows here are real but never ordered on screen.
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
        #expect(opening.toolbar.contains("Hide Sidebars"))
        #expect(!opening.toolbar.contains("Hide Sidebar"), "the system's hides only the worktrees")
        window.close()
    }

    @Test func aRepoWindowOpensInTheFrameItsRepoLastHad() throws {
        let requests = OpenRequests(defaults: try scratchDefaults())
        let saved = try onScreen(width: 1100, height: 700)
        requests.saveFrame(saved, for: "/r/a")
        let front = plainWindow()
        var windows = [front]

        requests.openWindow(
            for: URL(filePath: "/r/a"), windows: { windows },
            open: {
                #expect(requests.placement() == placement(saved))
                // SwiftUI cascades the new window from the front one.
                let new = plainWindow(saved)
                new.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY))
                windows.append(new)
            })

        #expect(windows[1].frame == saved)
        #expect(front.frame == plainWindow().frame)
        #expect(requests.placement() == WindowPlacement())
    }

    @Test func aRepoWithoutASavedFrameOpensWhereSwiftUIPutsIt() throws {
        let requests = OpenRequests(defaults: try scratchDefaults())
        let placed = NSRect(x: 40, y: 60, width: 1280, height: 800)
        var windows: [NSWindow] = []

        requests.openWindow(
            for: URL(filePath: "/r/a"), windows: { windows },
            open: { windows.append(plainWindow(placed)) })

        #expect(windows[0].frame == placed)
    }

    @Test func theLaunchWindowIsPlacedInTheFirstReopenedRepoFrame() throws {
        let defaults = try scratchDefaults()
        let first = FileManager.default.temporaryDirectory.path
        OpenRequests(defaults: defaults).windowOpened(first)
        let requests = OpenRequests(defaults: defaults)
        let saved = try onScreen(width: 1000, height: 650)
        requests.saveFrame(saved, for: first)

        #expect(requests.placement() == placement(saved))
        requests.launchHandled = true
        #expect(requests.placement() == WindowPlacement())
    }

    @Test func movingAShownWindowSavesItsFrameUnderItsRepo() throws {
        let requests = OpenRequests(defaults: try scratchDefaults())
        let window = plainWindow()
        let keeper = WindowFrameKeeper(isShown: { _ in true })
        keeper.attach(window, repo: "/r/a", frames: requests)

        let moved = NSRect(x: 60, y: 80, width: 1000, height: 640)
        window.setFrame(moved, display: false)

        #expect(requests.savedFrame(for: "/r/a") == moved)
        #expect(requests.savedFrame(for: "/r/b") == nil)
        #expect(window.tabbingMode == .disallowed)
    }

    @Test func aWelcomeWindowThatOpensARepoKeepsItsFrameAndSavesItForTheRepo() throws {
        let requests = OpenRequests(defaults: try scratchDefaults())
        requests.saveFrame(NSRect(x: 0, y: 0, width: 950, height: 600), for: "/r/a")
        let welcome = NSRect(x: 200, y: 220, width: 1280, height: 800)
        let window = plainWindow(welcome)
        let keeper = WindowFrameKeeper(isShown: { _ in true })
        keeper.attach(window, repo: nil, frames: requests)

        keeper.track("/r/a")

        #expect(window.frame == welcome)
        #expect(requests.savedFrame(for: "/r/a") == welcome)
    }

    @Test func aWindowSavesNothingBeforeItIsShown() throws {
        let requests = OpenRequests(defaults: try scratchDefaults())
        let window = plainWindow()
        WindowFrameKeeper().attach(window, repo: "/r/a", frames: requests)
        window.setFrame(NSRect(x: 10, y: 10, width: 999, height: 599), display: false)
        window.close()
        #expect(requests.savedFrame(for: "/r/a") == nil)
    }

    @Test func hideSidebarsLeavesTheDiffTheWholeWindowAndShowBringsBothBack() async throws {
        let repo = try await FixtureRepo()
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        let window = try window(showing: RepoWindow(session: session))
        await session.open()
        await session.settled()
        settleLayout()
        let columns = { () -> [Bool] in
            guard let split = splitViews(in: window).first else { return [] }
            return split.arrangedSubviews.map { split.isSubviewCollapsed($0) }
        }
        #expect(columns() == [false, false, false])
        let widths = { splitViews(in: window).first?.arrangedSubviews.map(\.frame.width) ?? [] }
        let before = widths()

        session.toggleSidebars()
        settleLayout()
        #expect(columns() == [true, true, false])
        session.showsThreadPanel.toggle()
        settleLayout()
        #expect(columns() == [true, true, false], "other updates keep the file list collapsed")
        #expect(session.columns == .diffOnly)

        session.toggleSidebars()
        settleLayout()
        #expect(columns() == [false, false, false])
        #expect(widths() == before, "both come back at the widths they had")
        let controller = splitViews(in: window).first?.delegate as? NSSplitViewController
        #expect(controller?.splitViewItems[1].canCollapse == false, "a drag can't close the files")

        session.columns = .filesAndDiff
        settleLayout()
        let filesAndDiff = widths()
        session.toggleSidebars()
        settleLayout()
        #expect(columns() == [true, true, false])
        session.columns = .filesAndDiff
        settleLayout()
        #expect(columns() == [true, false, false], "Show File List from hidden")
        #expect(widths() == filesAndDiff)
        window.close()
    }

    private func splitViews(in window: NSWindow) -> [NSSplitView] {
        func search(_ view: NSView) -> [NSSplitView] {
            ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(search)
        }
        return window.contentView.map(search) ?? []
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

    /// Saved frames off every display are ignored, so these sit on the main one.
    private func onScreen(width: Double, height: Double) throws -> NSRect {
        let screen = try #require(NSScreen.screens.first).visibleFrame
        return NSRect(x: screen.minX + 50, y: screen.minY + 40, width: width, height: height)
    }

    private func placement(_ frame: NSRect) -> WindowPlacement {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return WindowPlacement(CGPoint(x: frame.minX, y: top - frame.maxY), size: frame.size)
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
