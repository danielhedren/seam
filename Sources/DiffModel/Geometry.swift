import Foundation

/// Column positions for the current rows, mode and width.
package struct Geometry {
    package var visibleWidth = 0.0
    package var padding = 8.0
    package var numberWidth = 0.0
    var unifiedTextX = 0.0
    var splitTextOffset = 0.0
    package var columnWidth = 0.0
    package var documentWidth = 0.0
    var isSplit = false
    /// Characters per visual line when wrapping; nil when lines don't wrap.
    package var wrapColumns: Int?

    package init() {}

    package init(
        rows: [DiffRow], metrics: DiffLayout.Metrics, mode: DiffLayoutMode, visibleWidth: Double,
        wraps: Bool
    ) {
        self.visibleWidth = visibleWidth
        isSplit = mode == .split
        let character = metrics.characterWidth
        let digits = max(3, String(Self.largestNumber(rows)).count)
        numberWidth = Double(digits) * character + padding * 2
        let marker = character + padding
        unifiedTextX = numberWidth * 2 + marker
        splitTextOffset = numberWidth + marker
        let text = Double(DiffLayout.maxColumns(rows) + 2) * character + padding
        switch (mode, wraps) {
        case (.unified, false):
            columnWidth = max(visibleWidth, unifiedTextX + text)
            documentWidth = columnWidth
        case (.unified, true):
            columnWidth = visibleWidth
            documentWidth = visibleWidth
            wrapColumns = Self.columns(visibleWidth - unifiedTextX - padding, character)
        // Split columns stay at half the view so both sides are always visible; horizontal
        // scrolling would move the right side out of view.
        case (.split, _):
            columnWidth = max(visibleWidth / 2, splitTextOffset + character * 20)
            documentWidth = columnWidth * 2
            if wraps {
                wrapColumns = Self.columns(columnWidth - splitTextOffset - padding, character)
            }
        }
    }

    /// Where a side's text starts.
    package func textX(for side: DiffSide) -> Double {
        switch side {
        case .unified: unifiedTextX
        case .left: splitTextOffset
        case .right: columnWidth + splitTextOffset
        }
    }

    /// Where full-width rows (hunk titles, gaps, notices) put their text: in line with the code,
    /// which in split mode is the left column's.
    package var chromeTextX: Double { isSplit ? splitTextOffset : unifiedTextX }

    /// At least 20 columns, so a narrow window still wraps into readable lines.
    private static func columns(_ width: Double, _ character: Double) -> Int {
        max(20, Int(width / character))
    }

    private static func largestNumber(_ rows: [DiffRow]) -> Int {
        rows.reduce(0) { largest, row in
            switch row {
            case .line(_, let line): max(largest, line.old ?? 0, line.new ?? 0)
            case .split(_, let left, let right):
                max(largest, left?.number ?? 0, right?.number ?? 0)
            default: largest
            }
        }
    }
}
