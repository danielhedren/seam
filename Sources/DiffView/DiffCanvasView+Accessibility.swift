import AppKit
import GitKit
import SeamCore

/// Each visible row is an accessibility element that reads its kind, number and text.
extension DiffCanvasView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        String(localized: "Diff", bundle: .module)
    }

    override func accessibilityChildren() -> [Any]? {
        layout.rows(in: visibleRect.minY, visibleRect.maxY).map { index in
            let rect = NSRect(
                x: 0, y: layout.top(of: index), width: bounds.width,
                height: layout.height(of: index))
            let frame = window?.convertToScreen(convert(rect, to: nil)) ?? rect
            return NSAccessibilityElement.element(
                withRole: .staticText, frame: frame, label: accessibilityLabel(row: index),
                parent: self)
        }
    }

    private func accessibilityLabel(row index: Int) -> String {
        func describe(_ kind: DiffLine.Kind, _ number: Int?, isOld: Bool, _ text: String) -> String
        {
            let kindName =
                switch kind {
                case .added: String(localized: "added", bundle: .module)
                case .removed: String(localized: "removed", bundle: .module)
                case .context: String(localized: "unchanged", bundle: .module)
                }
            guard let number else { return "\(kindName): \(text)" }
            return isOld
                ? String(localized: "\(kindName), old line \(number): \(text)", bundle: .module)
                : String(localized: "\(kindName), new line \(number): \(text)", bundle: .module)
        }
        switch layout.rows[index] {
        case .fileHeader(let file): return review.files[file].diff.path
        case .hunkHeader(_, _, let text), .notice(_, let text): return text
        case .gap(_, let gap):
            return String(localized: "\(gap.hidden) unchanged lines hidden", bundle: .module)
        case .image:
            return String(localized: "Image preview, old and new", bundle: .module)
        case .line(_, let line):
            return describe(line.kind, line.new ?? line.old, isOld: line.new == nil, line.text)
        case .split(_, let left, let right):
            return [
                left.map { describe($0.kind, $0.number, isOld: true, $0.text) },
                right.map { describe($0.kind, $0.number, isOld: false, $0.text) },
            ].compactMap(\.self).joined(separator: "; ")
        }
    }
}
