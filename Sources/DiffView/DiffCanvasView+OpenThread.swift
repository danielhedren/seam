import AppKit
import SeamCore

/// The conversation of the thread open in the diff (SPEC §7.7). Features draws it; the canvas
/// puts it in the thread's row, which is as tall as the view says it needs at the row's width.
@MainActor
public protocol InlineThreadView: NSView {
    func height(forWidth width: Double) -> Double
}

/// Where an open thread's text starts inside its view, so it lines up with the composer's.
@MainActor
public enum InlineThreadMetrics {
    public static let textInset = DraftEditor.textInset - DraftEditor.margin
}

extension DiffCanvasView {
    /// The row's height for its conversation: measured at the card's inner width, with the
    /// card's margins. Makes the view on first need and drops one for another thread.
    func openThreadHeight(in rows: [DiffRow]) -> Double {
        guard
            let marker = rows.lazy.compactMap({ row -> ThreadMarker? in
                if case .openThread(_, let marker) = row { marker } else { nil }
            }).first,
            let view = threadView(for: marker.id)
        else { return 0 }
        let card = mode == .split ? geometry.columnWidth : geometry.visibleWidth
        let inner = max(card - 16 - 2 * DraftEditor.margin, 100)
        return (view.height(forWidth: inner) + 8 + 2 * DraftEditor.margin).rounded(.up)
    }

    private func threadView(for id: String) -> (any InlineThreadView)? {
        if let threadView, threadView.id == id { return threadView.view }
        removeThreadView()
        guard let view = makeThreadView?(id) else { return nil }
        addSubview(view)
        threadView = (id, view)
        return view
    }

    /// Keeps the view on its row, and removes it with the row, handing focus back.
    func updateThreadView() {
        guard let row = openThreadRow, case .openThread(_, let marker) = layout.rows[row],
            let threadView, threadView.id == marker.id
        else {
            removeThreadView()
            return
        }
        threadView.view.frame = draftFrame(row: row, side: marker.side)
            .insetBy(dx: DraftEditor.margin, dy: DraftEditor.margin)
    }

    private func removeThreadView() {
        guard let view = threadView?.view else { return }
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: view) == true
        view.removeFromSuperview()
        threadView = nil
        if hadFocus { window?.makeFirstResponder(self) }
    }

    var openThreadRow: Int? {
        layout.rows.firstIndex { if case .openThread = $0 { true } else { false } }
    }
}
