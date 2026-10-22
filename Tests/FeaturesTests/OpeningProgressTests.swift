import AppKit
import SwiftUI
import TestSupport
import Testing

@testable import Features

/// SPEC §9: progress shows only after 150 ms, so a fast open doesn't flicker.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OpeningProgressTests {
    @Test func openingProgressAppearsOnlyAfter150Milliseconds() async throws {
        let clock = ManualClock()
        let host = NSHostingView(rootView: OpeningProgress(name: "seam", clock: clock))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        await drain()
        try #require(try isBlank(host))

        await clock.sleepers()
        clock.advance(by: .milliseconds(150))
        await drain()
        #expect(try !isBlank(host))
    }

    /// Lets the view's task and SwiftUI's layout run.
    private func drain() async {
        for _ in 0..<10 {
            await Task.yield()
            pumpRunLoop()
        }
    }

    /// Synchronous because `RunLoop.run` isn't available from async code.
    private func pumpRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    /// Whether every pixel has the same colour, i.e. nothing is drawn.
    private func isBlank(_ view: NSView) throws -> Bool {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let first = rep.colorAt(x: 0, y: 0)
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2)
            where rep.colorAt(x: x, y: y) != first {
                return false
            }
        }
        return true
    }
}
