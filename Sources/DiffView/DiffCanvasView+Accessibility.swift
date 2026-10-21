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

    /// Visible rows as elements, grouped by hunk so VoiceOver can move hunk by hunk.
    override func accessibilityChildren() -> [Any]? {
        let groups = layout.hunkGroups(layout.rows(in: visibleRect.minY, visibleRect.maxY))
        return groups.flatMap { group -> [Any] in
            guard let header = group.header else {
                return group.rows.map { element(for: $0, parent: self) }
            }
            let rows = [header] + group.rows
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.group)
            element.setAccessibilityLabel(accessibilityLabel(row: header))
            element.setAccessibilityParent(self)
            element.setAccessibilityFrame(screenFrame(rows.first ?? header, rows.last ?? header))
            element.setAccessibilityChildren(
                group.rows.map { self.element(for: $0, parent: element) })
            return [element]
        }
    }

    private func element(for row: Int, parent: Any) -> Any {
        NSAccessibilityElement.element(
            withRole: .staticText, frame: screenFrame(row, row),
            label: accessibilityLabel(row: row),
            parent: parent)
    }

    private func screenFrame(_ first: Int, _ last: Int) -> NSRect {
        let rect = NSRect(
            x: 0, y: layout.top(of: first), width: bounds.width,
            height: layout.top(of: last + 1) - layout.top(of: first))
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
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
