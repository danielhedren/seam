import AppKit
import SwiftUI
import Testing

@testable import Features
@testable import ReviewModel

/// The file filter's keyboard behaviour, in a window that is never shown.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FilterFieldTests {
    @Observable final class Probe {
        var text = "delivery"
        var focused = false
        var focusRequests = 0
        var left = 0
    }

    private struct Host: View {
        @Bindable var probe: Probe
        @FocusState private var focus: Bool

        var body: some View {
            FilterField(text: $probe.text, focus: $focus) { probe.left += 1 }
                .onChange(of: probe.focusRequests) { focus = true }
                .onChange(of: focus) { _, now in probe.focused = now }
                .padding()
        }
    }

    @Test func escapeClearsTheFilterThenLeavesTheField() throws {
        let probe = Probe()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(probe: probe))
        settle()
        probe.focusRequests += 1
        settle()
        #expect(probe.focused)

        try escape(window)
        #expect(probe.text.isEmpty)
        #expect(probe.focused)
        #expect(probe.left == 0)

        try escape(window)
        #expect(!probe.focused)
        #expect(probe.left == 1)
    }

    private func escape(_ window: NSWindow) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(event)
        settle()
    }
}

@MainActor
private func settle() {
    runLoop(for: 0.2)
}
