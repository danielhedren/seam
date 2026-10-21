import AppKit
import GitKit
import SeamCore

/// Mouse selection, word and line selection, copy and select-all, on the row model.
extension DiffCanvasView {
    func position(at point: NSPoint) -> (DiffSide, TextPosition)? {
        guard let row = layout.row(at: point.y) else { return nil }
        let side: DiffSide =
            mode == .unified ? .unified : point.x < geometry.columnWidth ? .left : .right
        let textX =
            switch side {
            case .unified: geometry.unifiedTextX
            case .left: geometry.splitTextOffset
            case .right: geometry.columnWidth + geometry.splitTextOffset
            }
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
            onToggleCollapse?(review.files[file].diff.path)
            return
        case .gap(let file, let gap):
            let column = Int((point.x - geometry.unifiedTextX) / layout.metrics.characterWidth)
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
            selection = wordSelection(side: side, at: position)
        case 3...:
            let length = layout.text(of: position.row, side: side)?.count ?? 0
            selection = DiffSelection(
                side: side, anchor: TextPosition(row: position.row, column: 0),
                head: TextPosition(row: position.row, column: length + 1))
        default:
            if event.modifierFlags.contains(.shift), let current = selection {
                selection = DiffSelection(
                    side: current.side, anchor: current.anchor, head: position)
            } else {
                selection = DiffSelection(side: side, anchor: position, head: position)
            }
        }
        dragStart = position
    }

    override func mouseDragged(with event: NSEvent) {
        guard let current = selection, dragStart != nil else { return }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let (_, position) = self.position(at: point) else { return }
        selection = DiffSelection(side: current.side, anchor: current.anchor, head: position)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    private func wordSelection(side: DiffSide, at position: TextPosition) -> DiffSelection {
        let characters = Array(layout.text(of: position.row, side: side) ?? "")
        func isWord(_ index: Int) -> Bool {
            characters.indices.contains(index)
                && (characters[index].isLetter || characters[index].isNumber
                    || characters[index] == "_")
        }
        var start = position.column
        var end = position.column
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        if start == end, end < characters.count { end += 1 }
        return DiffSelection(
            side: side, anchor: TextPosition(row: position.row, column: start),
            head: TextPosition(row: position.row, column: end))
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
