import AppKit
import SwiftUI

/// Each repo's window reopens in its last frame (SPEC §7.1). SwiftUI replaces frame autosave
/// names with its own per-slot ones, so the frames are kept here instead.
extension OpenRequests {
    /// SwiftUI orders the window in inside `open`, sized by `placement()` but cascaded from the
    /// front window. AppKit commits a run-loop turn's window changes together, so the window
    /// appears at the origin set here; its view gets the window too late for that.
    func openWindow(
        for main: URL, windows: () -> [NSWindow] = { NSApp.windows }, open: () -> Void
    ) {
        let existing = Set(windows().map(ObjectIdentifier.init))
        placing = main.path
        defer { placing = nil }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            open()
            guard let frame = savedFrame(for: main.path), Self.isOnScreen(frame) else { return }
            for window in windows() where !existing.contains(ObjectIdentifier(window)) {
                window.setFrame(frame, display: false)
            }
        }
    }

    /// The saved frame of the repo `openWindow(for:)` is opening, or for the launch window the
    /// workspace's first. A placement's origin is its top left, down from the main display's top.
    func placement() -> WindowPlacement {
        guard let repo = placing ?? (launchHandled ? nil : reopenedWorkspace.first),
            let frame = savedFrame(for: repo), Self.isOnScreen(frame),
            let top = NSScreen.screens.first?.frame.maxY
        else { return WindowPlacement() }
        return WindowPlacement(CGPoint(x: frame.minX, y: top - frame.maxY), size: frame.size)
    }

    /// A frame on a display that's gone since would put the window out of reach.
    private static func isOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }
}

/// Saves a window's frame under its repo whenever it changes on screen, and when it closes.
@MainActor
final class WindowFrameKeeper {
    private weak var window: NSWindow?
    private var repo: String?
    private var frames: OpenRequests?
    private var observation: NSKeyValueObservation?
    private var closing: NSObjectProtocol?
    private let isShown: (NSWindow) -> Bool

    init(isShown: @escaping (NSWindow) -> Bool = \.isVisible) {
        self.isShown = isShown
    }

    func attach(_ window: NSWindow, repo: String?, frames: OpenRequests) {
        guard self.window !== window else { return }
        self.window = window
        self.frames = frames
        self.repo = repo
        window.tabbingMode = .disallowed
        observation = window.observe(\.frame) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.save() }
        }
        closing = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    /// A window that turns into a repo's window keeps the frame it has and saves it from then on.
    func track(_ repo: String?) {
        self.repo = repo
        save()
    }

    private func save() {
        guard let window, let repo, let frames, isShown(window),
            !window.styleMask.contains(.fullScreen)
        else { return }
        frames.saveFrame(window.frame, for: repo)
    }

    isolated deinit {
        if let closing { NotificationCenter.default.removeObserver(closing) }
    }
}
