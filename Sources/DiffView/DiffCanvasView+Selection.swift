import AppKit
import DiffModel
import GitKit
import SeamCore

/// Mouse selection, word and line selection, copy and select-all, on the row model.
extension DiffCanvasView {
    func position(at point: NSPoint) -> (DiffSide, TextPosition)? {
        guard let row = layout.row(at: point.y) else { return nil }
        let side: DiffSide =
            mode == .unified ? .unified : point.x < geometry.columnWidth ? .left : .right
        let textX = geometry.textX(for: side)
        let length = layout.text(of: row, side: side)?.count ?? 0
        var column = Int(((point.x - textX) / layout.metrics.characterWidth).rounded())
        if let wrap = layout.wrapColumns {
            let line = Int((point.y - layout.top(of: row)) / layout.metrics.lineHeight)
            column = line * wrap + min(max(column, 0), wrap)
        }
        return (side, TextPosition(row: row, column: min(max(column, 0), length)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let (side, position) = self.position(at: point) else { return }
        switch layout.rows[position.row] {
        case .fileHeader(let file):
            let path = review.files[file].diff.path
            let header = DiffHeaderDrawing.layout(
                review.files[file], viewed: viewed[path] ?? .unviewed,
                sinceViewed: sinceViewed.contains(path), in: chromeRect(ofRow: position.row),
                font: font, palette: .light)
            if header.viewedFrame.contains(point) {
                onToggleViewed?(path)
            } else {
                onToggleCollapse?(path)
            }
            return
        case .thread(_, let marker):
            onOpenThread?(marker.id)
            return
        case .gap(let file, let gap):
            let column = Int(
                ((point.x - geometry.chromeTextX) / layout.metrics.characterWidth).rounded(.down))
            if let control = DiffRowBuilder.gapLabel(gap).controls.first(where: {
                $0.0.contains(column)
            }) {
                onExpand?(review.files[file].diff.path, gap.gap, control.1)
            }
            return
        default:
            break
        }
        switch event.clickCount {
        case 2:
            let words = layout.word(at: position, side: side)
            selection = DiffSelection(
                side: side, anchor: TextPosition(row: position.row, column: words.lowerBound),
                head: TextPosition(row: position.row, column: words.upperBound))
        case 3...:
            selection = lineSelection(side: side, row: position.row)
        default:
            if event.modifierFlags.contains(.shift), let current = selection {
                selection = DiffSelection(
                    side: current.side, anchor: current.anchor, head: position)
            } else {
                selection = DiffSelection(side: side, anchor: position, head: position)
            }
        }
        isDragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let current = selection, isDragging else { return }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let (_, position) = self.position(at: point) else { return }
        selection = DiffSelection(side: current.side, anchor: current.anchor, head: position)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }

    /// The whole line and its newline, as a triple click selects it.
    private func lineSelection(side: DiffSide, row: Int) -> DiffSelection {
        let length = layout.text(of: row, side: side)?.count ?? 0
        return DiffSelection(
            side: side, anchor: TextPosition(row: row, column: 0),
            head: TextPosition(row: row, column: length + 1))
    }

    /// A right click on lines selects them first unless it's inside the selection, so the menu
    /// acts on what's highlighted.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let (side, position) = self.position(at: point) else { return super.menu(for: event) }
        switch layout.rows[position.row] {
        case .fileHeader(let file):
            return menuForFile?(review.files[file].diff.path)
        case .line, .split:
            if !selectionContains(position.row) {
                selection = lineSelection(side: side, row: position.row)
            }
            return menuForLines?()
        default:
            return super.menu(for: event)
        }
    }

    private func selectionContains(_ row: Int) -> Bool {
        guard let selection, !selection.isEmpty else { return false }
        return selection.start.row...selection.end.row ~= row
    }

    /// Where a new thread would go: the selected lines, or `row`'s line without a selection,
    /// within the first selected row's file. Unchanged lines go on the new side whichever column
    /// they were picked in, so a thread on them follows the code as it's edited; only a
    /// selection of removed lines alone goes on the old side.
    func commentTarget(fallback row: Int?) -> (
        file: Int, side: ThreadAnchor.Side, lines: ClosedRange<Int>
    )? {
        let range: ClosedRange<Int>
        if let selection, !selection.isEmpty {
            range = selection.start.row...selection.end.row
        } else if let row {
            range = row...row
        } else {
            return nil
        }
        guard layout.rows.indices.contains(range.lowerBound) else { return nil }
        let file = layout.rows[range.lowerBound].file
        let rows = range.clamped(to: 0...(layout.rows.count - 1)).map { layout.rows[$0] }
            .filter { $0.file == file }
        let leftColumn = mode == .split && selection?.side == .left
        var new: [Int] = []
        var old: [Int] = []
        for row in rows {
            switch row {
            case .line(_, let line):
                if line.kind == .removed {
                    old += [line.old].compactMap(\.self)
                } else {
                    new += [line.new].compactMap(\.self)
                }
            case .split(_, let left, let right) where leftColumn:
                if left?.kind == .removed { old += [left?.number].compactMap(\.self) }
                if left?.kind == .context { new += [right?.number].compactMap(\.self) }
            case .split(_, _, let right):
                new += [right?.number].compactMap(\.self)
            default:
                break
            }
        }
        if let first = new.min(), let last = new.max() { return (file, .new, first...last) }
        if let first = old.min(), let last = old.max() { return (file, .old, first...last) }
        return nil
    }

    var selectedText: String? {
        guard let selection, !selection.isEmpty else { return nil }
        return layout.text(of: selection)
    }

    @objc func copy(_ sender: Any?) {
        guard let selection, !selection.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(layout.text(of: selection), forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard !layout.rows.isEmpty else { return }
        let side: DiffSide = mode == .unified ? .unified : selection?.side ?? .right
        let last = layout.rows.count - 1
        selection = DiffSelection(
            side: side, anchor: TextPosition(row: 0, column: 0),
            head: TextPosition(row: last, column: (layout.text(of: last, side: side)?.count ?? 0)))
    }
}

extension DiffCanvasView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selection.map { !$0.isEmpty } ?? false }
        return true
    }
}
