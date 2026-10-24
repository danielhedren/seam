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
            case .thread:
                regions.append((row, .control))
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
        // Kept with the cursor rects, which are redone for the visible rows on every scroll.
        removeAllToolTips()
        guard viewedHelp != nil else { return }
        for index in layout.rows(in: visibleRect.minY, visibleRect.maxY) {
            guard case .fileHeader(let file) = layout.rows[index] else { continue }
            addToolTip(viewedFrame(ofFile: file, row: index), owner: self, userData: nil)
        }
    }

    func viewedFrame(ofFile file: Int, row: Int) -> NSRect {
        let path = review.files[file].diff.path
        return DiffHeaderDrawing.layout(
            review.files[file], viewed: viewed[path] ?? .unviewed,
            sinceViewed: sinceViewed.contains(path), in: chromeRect(ofRow: row), font: font,
            palette: .light
        ).viewedFrame
    }

    /// The checkbox's tooltip at `point`, if it's on one.
    func viewedToolTip(at point: NSPoint) -> String? {
        guard let viewedHelp else { return nil }
        for index in layout.rows(in: point.y, point.y) {
            guard case .fileHeader(let file) = layout.rows[index],
                viewedFrame(ofFile: file, row: index).contains(point)
            else { continue }
            return viewedHelp(viewed[review.files[file].diff.path] ?? .unviewed)
        }
        return nil
    }
}

extension DiffCanvasView: NSViewToolTipOwner {
    nonisolated func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        MainActor.assumeIsolated { viewedToolTip(at: point) ?? "" }
    }
}
