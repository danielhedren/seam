import AppKit
import DiffModel
import DiffView
import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import SwiftUI
import Synchronization
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

/// A diff view showing the selected worktree's diff, wired to the session as the window does.
@MainActor
@discardableResult
func showDiff(_ session: RepoSession) throws -> DiffScrollView {
    let view = DiffScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    session.diff.view = view
    view.show(try #require(session.selected?.content), position: .top)
    return view
}

/// One short turn of the run loop, for AppKit and SwiftUI layout; a sync function, since an
/// async one can't run the loop itself.
@MainActor
/// Runs the main run loop in short slices: on battery the system lets a 10 ms run loop
/// timer fire 100 ms late in an AppKit process, which slowed window tests past their limits.
func runLoopOnce() {
    runLoop(for: 0.01)
}

func runLoop(for seconds: TimeInterval) {
    let end = Date(timeIntervalSinceNow: seconds)
    while Date() < end { _ = CFRunLoopRunInMode(.defaultMode, 0.0001, false) }
}

/// The real diff pane in a window that's never shown, for driving it end to end.
@MainActor
struct CardWindow {
    let window: NSWindow

    init(session: RepoSession, review: WorktreeReview) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DiffPane(session: session, review: review))
    }

    /// Settles until `condition` holds, for a bounded time; false if it never did.
    func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() {
                await settle()
                return true
            }
            await settle()
        }
        return condition()
    }

    /// Lets SwiftUI, AppKit and the card's main-actor tasks all catch up.
    func settle() async {
        for _ in 0..<30 {
            runLoopOnce()
            await Task.yield()
        }
    }
}

/// The Threads navigator in a window that's never shown.
@MainActor
struct ThreadsWindow {
    let window: NSWindow

    init(session: RepoSession, review: WorktreeReview) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ThreadsList(session: session, review: review))
    }

    func settle() async {
        for _ in 0..<30 {
            runLoopOnce()
            await Task.yield()
        }
    }

    func png() throws -> Data? {
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

extension CardWindow {
    var host: ThreadCardHost? { Self.find(ThreadCardHost.self, in: window.contentView) }

    func textField(in view: NSView) -> NSView? {
        Self.find(NSTextView.self, in: view) ?? Self.find(NSTextField.self, in: view)
    }

    /// The card is exactly as tall as its contents need, so nothing hangs out of it.
    func fits() throws -> Bool {
        let card = try #require(host)
        // Rows are whole points; on a 2x screen the card can want half a point less.
        return card.frame.height == card.height(forWidth: card.frame.width).rounded(.up)
    }

    func press(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false,
                keyCode: key == "\r" ? 36 : 53)
        else { return }
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        return (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }
}
