import AppKit

/// Pointer shapes: an I-beam over selectable text, a pointing hand over what a click acts on
/// (file headers, gap controls, thread rows), as in a web diff or Xcode's comparison view.
extension DiffCanvasView {
    enum CursorKind: Equatable {
        case text
        case control
    }

    /// The cursor regions of the rows that meet `rect`.
    func cursorRegions(in rect: NSRect) -> [(rect: NSRect, kind: CursorKind)] {
        var regions: [(rect: NSRect, kind: CursorKind)] = []
        let width = layout.metrics.characterWidth
        for index in layout.rows(in: rect.minY, rect.maxY) {
            let row = NSRect(
                x: 0, y: layout.top(of: index), width: bounds.width,
                height: layout.height(of: index))
            switch layout.rows[index] {
            case .line, .split:
                regions.append((row, .text))
            case .fileHeader:
                regions.append((chromeRect(ofRow: index), .control))
            case .thread(_, let marker):
                var band = row
                if mode == .split {
                    band.size.width = geometry.columnWidth
                    if marker.side == .new { band.origin.x = geometry.columnWidth }
                }
                regions.append((band, .control))
            case .gap(_, let gap):
                for (columns, _) in DiffRowBuilder.gapLabel(gap).controls {
                    regions.append(
                        (
                            NSRect(
                                x: geometry.chromeTextX + Double(columns.lowerBound) * width,
                                y: row.minY, width: Double(columns.count) * width,
                                height: row.height), .control
                        ))
                }
            case .hunkHeader, .notice, .image, .draft, .openThread:
                break
            }
        }
        return regions
    }

    override func resetCursorRects() {
        for region in cursorRegions(in: visibleRect) {
            addCursorRect(region.rect, cursor: region.kind == .text ? .iBeam : .pointingHand)
        }
    }
}
