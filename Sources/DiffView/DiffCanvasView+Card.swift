import AppKit
import SeamCore

/// What the diff's one card holds (SPEC §7.7): a new thread being written, or an open thread.
public enum DiffCard: Equatable, Sendable {
    case draft(DraftMarker)
    case thread(String)
}

/// The card's contents, which Features draws; the canvas draws the amber frame, puts the view
/// in it, and makes the row as tall as the view says it needs at the row's width. The view's
/// content updates after the model does, so it says when that height changes (a reply
/// arrived), and the canvas measures again.
@MainActor
public protocol DiffCardView: NSView {
    func height(forWidth width: Double) -> Double
    var onHeightChange: (() -> Void)? { get set }
}

public enum DiffCardMetrics {
    /// From the frame to the view, on every side.
    public static let margin = 8.0
}

extension DiffCanvasView {
    /// The card row's height: the view's, measured at the frame's inner width, plus the
    /// frame's insets. Makes the view on first need and drops one that shows something else.
    func cardHeight(in rows: [DiffRow]) -> Double {
        guard let (_, card, _) = Self.card(in: rows), let view = cardView(for: card)
        else { return 0 }
        let width = (mode == .split ? geometry.columnWidth : geometry.visibleWidth) - 16
        let inner = max(width - 2 * DiffCardMetrics.margin, 100)
        return (view.height(forWidth: inner) + 8 + 2 * DiffCardMetrics.margin).rounded(.up)
    }

    private func cardView(for card: DiffCard) -> (any DiffCardView)? {
        if let shownCard, shownCard.card == card { return shownCard.view }
        removeCardView()
        guard let view = makeCardView?(card) else { return nil }
        view.onHeightChange = { [weak self] in self?.remeasureCard() }
        addSubview(view)
        shownCard = (card, view)
        return view
    }

    /// Keeps the view in its row's frame, and removes it with the row, handing focus back.
    func updateCardView() {
        guard let (row, card, side) = Self.card(in: layout.rows), let shownCard,
            shownCard.card == card
        else {
            removeCardView()
            return
        }
        shownCard.view.frame = draftFrame(row: row, side: side)
            .insetBy(dx: DiffCardMetrics.margin, dy: DiffCardMetrics.margin)
    }

    private func removeCardView() {
        guard let view = shownCard?.view else { return }
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: view) == true
        view.removeFromSuperview()
        shownCard = nil
        if hadFocus { window?.makeFirstResponder(self) }
    }

    static func card(in rows: [DiffRow]) -> (row: Int, card: DiffCard, side: ThreadAnchor.Side)? {
        for (index, row) in rows.enumerated() {
            switch row {
            case .draft(_, let marker): return (index, .draft(marker), marker.side)
            case .openThread(_, let marker): return (index, .thread(marker.id), marker.side)
            default: continue
            }
        }
        return nil
    }

    var cardRow: Int? { Self.card(in: layout.rows)?.row }

    var openThreadRow: Int? {
        layout.rows.firstIndex { if case .openThread = $0 { true } else { false } }
    }
}
