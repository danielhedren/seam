import AppKit
import DiffModel

/// A strip down the diff's right edge with a tick where each thread's row is, so threads are
/// seen before they're scrolled to (SPEC §7.7). A view of its own over the scroller: overlay
/// scrollers don't call `draw(_:)`, and a legacy one draws its knob over anything drawn there.
final class ThreadRuler: NSView {
    static let width = 8.0

    var spans: [DiffLayout.ThreadSpan] = [] {
        didSet { if spans != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    /// Clicks go through to the scroller underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        for span in spans {
            let height = max(span.height * bounds.height, 3)
            let y = min(span.top * bounds.height, bounds.height - height)
            let color =
                span.marker.isResolved
                ? NSColor.systemGray
                : ThreadColor.accent(span.marker.source, note: span.marker.isNote)
            color.setFill()
            NSRect(x: bounds.maxX - 5, y: y.rounded(), width: 3, height: height.rounded()).fill()
        }
    }
}
