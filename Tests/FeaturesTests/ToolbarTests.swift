import AppKit
import SeamCore
import SwiftUI
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

/// The review toolbar as AppKit builds it, in a window that is never shown.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ToolbarTests {
    @Test func theThreadsButtonBadgesTheOpenThreadsAndNoneAtZero() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        let repository = try #require(session.repository)
        let anchor = try #require(review.anchor(path: "a.txt", side: .new, lines: 1...1))
        let ids = try session.services.threads.update(repository) { threads throws(ThreadError) in
            var ids: [String] = []
            for _ in 0..<3 {
                ids.append(
                    try ThreadRules.open(
                        &threads, worktree: review.id, anchor: anchor, author: "claude",
                        body: "Why?", now: .now
                    ).id)
            }
            return ids
        }
        await session.threads?.load()
        let window = toolbarWindow(session, review)
        #expect(threadsItem(window)?.badge?.text == "3")

        await session.setResolved(true, thread: ids[0])
        settle()
        #expect(threadsItem(window)?.badge?.text == "2")

        for id in ids.dropFirst() { await session.setResolved(true, thread: id) }
        settle()
        #expect(threadsItem(window) != nil)
        #expect(threadsItem(window)?.badge == nil)
    }

    @Test func theViewModeControlFollowsTheSettingTheSKeyFlips() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let window = toolbarWindow(session, try #require(session.selected))
        let item = try #require(window.toolbar?.items.first { $0.label == "View Mode" })
        #expect(item.toolTip == "Unified or side by side (S)")
        #expect(session.settings.layoutMode == .unified)

        session.toggleMode()
        #expect(session.settings.layoutMode == .split)
    }

    private func toolbarWindow(_ session: RepoSession, _ review: WorktreeReview) -> NSWindow {
        let root = NavigationStack {
            Color.clear.toolbar { ReviewToolbar(session: session, review: review) }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: root)
        settle()
        return window
    }

    private func threadsItem(_ window: NSWindow) -> NSToolbarItem? {
        window.toolbar?.items.first { $0.label == "Threads" }
    }
}

@MainActor
private func settle() {
    runLoop(for: 0.4)
}
