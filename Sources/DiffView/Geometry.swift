import Foundation

/// Column positions for the current layout and width.
struct Geometry {
    var visibleWidth = 0.0
    var padding = 8.0
    var numberWidth = 0.0
    var unifiedTextX = 0.0
    var splitTextOffset = 0.0
    var columnWidth = 0.0
    var documentWidth = 0.0

    init() {}

    init(layout: DiffLayout, mode: DiffLayoutMode, visibleWidth: Double) {
        self.visibleWidth = visibleWidth
        let character = layout.metrics.characterWidth
        let digits = max(3, String(Self.largestNumber(layout.rows)).count)
        numberWidth = Double(digits) * character + padding * 2
        let marker = character + padding
        unifiedTextX = numberWidth * 2 + marker
        splitTextOffset = numberWidth + marker
        let text = Double(layout.maxColumns + 2) * character + padding
        switch mode {
        case .unified:
            columnWidth = max(visibleWidth, unifiedTextX + text)
            documentWidth = columnWidth
        // Split columns stay at half the view so both sides are always visible; horizontal
        // scrolling would move the right side out of view.
        case .split:
            columnWidth = max(visibleWidth / 2, splitTextOffset + character * 20)
            documentWidth = columnWidth * 2
        }
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
