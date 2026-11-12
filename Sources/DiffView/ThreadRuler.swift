import AppKit
import DiffModel

/// A strip down the diff's right edge with a tick where each thread's row is, so threads are
/// seen before they're scrolled to (SPEC §7.7), over thin grey marks where the changes are
/// (§7.4). A view of its own over the scroller: overlay scrollers don't call `draw(_:)`, and a
/// legacy one draws its knob over anything drawn there.
final class ThreadRuler: NSView {
    static let width = 10.0

    var spans: [DiffLayout.ThreadSpan] = [] {
        didSet { if spans != oldValue { needsDisplay = true } }
    }
    var changes: [DiffLayout.ChangeSpan] = [] {
        didSet { if changes != oldValue { needsDisplay = true } }
    }

    /// Marks closer than this on screen are drawn as one, so a long diff isn't a solid bar.
    static let mergeGap = 2.0

    /// Each run in points, merged where they nearly touch; a merged run is dimmed only when all
    /// of it is viewed.
    static func changeRects(_ changes: [DiffLayout.ChangeSpan], height: Double)
        -> [(rect: NSRect, isViewed: Bool)]
    {
        var merged: [(top: Double, bottom: Double, isViewed: Bool)] = []
        for change in changes {
            let top = change.top * height
            let bottom = top + max(change.height * height, 2)
            if let last = merged.last, top - last.bottom < mergeGap {
                merged[merged.count - 1].bottom = max(last.bottom, bottom)
                merged[merged.count - 1].isViewed = last.isViewed && change.isViewed
            } else {
                merged.append((top, bottom, change.isViewed))
            }
        }
        return merged.map { run in
            (NSRect(x: 0, y: run.top, width: 2, height: run.bottom - run.top), run.isViewed)
        }
    }

    override var isFlipped: Bool { true }

    /// Clicks go through to the scroller underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Thinner and further in than thread ticks, and grey, so the two never read alike.
        for change in Self.changeRects(changes, height: bounds.height) {
            NSColor.secondaryLabelColor.withAlphaComponent(change.isViewed ? 0.25 : 0.7).setFill()
            change.rect.offsetBy(dx: bounds.maxX - 9, dy: 0).fill()
        }
        for span in spans {
            let height = max(span.height * bounds.height, 4)
            let y = min(span.top * bounds.height, bounds.height - height)
            let color =
                span.marker.isResolved
                ? NSColor.systemGray
                : ThreadColor.accent(span.marker.source, note: span.marker.isNote)
            color.setFill()
            NSRect(x: bounds.maxX - 7, y: y.rounded(), width: 5, height: height.rounded()).fill()
        }
    }
}
