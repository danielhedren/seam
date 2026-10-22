import Foundation
import GitKit

/// Gaps between hunks: where they are, what they reveal, and their controls (SPEC §7.4).
extension DiffRowBuilder {
    /// A hunk's first line on each side. A side with no lines names the line before it.
    static func first(_ hunk: Hunk) -> (old: Int, new: Int) {
        (
            hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart,
            hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart
        )
    }

    /// The first line after a hunk on each side.
    static func next(_ hunk: Hunk) -> (old: Int, new: Int) {
        (
            hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart + hunk.oldCount,
            hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart + hunk.newCount
        )
    }

    /// Revealed context at the top and bottom of a gap, with the hidden rest as one gap row.
    static func gapRows(
        file: Int, gap: Int, newRange: Range<Int>, oldOffset: Int, lines: [Substring],
        expansion: GapExpansion, mode: DiffLayoutMode, lookup: SyntaxLookup, isFirst: Bool,
        isLast: Bool
    ) -> [DiffRow] {
        let range = newRange.clamped(to: 1..<(lines.count + 1))
        guard !range.isEmpty else { return [] }
        let top = isFirst ? 0 : min(expansion.top, range.count)
        let bottom = isLast ? 0 : min(expansion.bottom, range.count - top)
        let all = expansion.top >= range.count
        func context(_ numbers: Range<Int>) -> [DiffRow] {
            numbers.map { number in
                let raw = String(lines[number - 1])
                let text = TabStops.expand(raw, width: lookup.tabWidth)
                let old = number + oldOffset
                let syntax = lookup.new(number, raw: raw)
                return switch mode {
                case .unified:
                    .line(
                        file: file,
                        UnifiedLine(
                            old: old, new: number, kind: .context, text: text, syntax: syntax))
                case .split:
                    .split(
                        file: file,
                        left: SideLine(kind: .context, number: old, text: text, syntax: syntax),
                        right: SideLine(kind: .context, number: number, text: text, syntax: syntax))
                }
            }
        }
        if all { return context(range) }
        var rows = context(range.lowerBound..<(range.lowerBound + top))
        let hidden = range.count - top - bottom
        if hidden > 0 {
            rows.append(
                .gap(
                    file: file,
                    GapRow(gap: gap, hidden: hidden, canExpandDown: !isFirst, canExpandUp: !isLast))
            )
        }
        rows += context((range.upperBound - bottom)..<range.upperBound)
        return rows
    }

    /// The gap row's text and the character ranges of its controls.
    static func gapLabel(_ gap: GapRow) -> (text: String, controls: [(Range<Int>, ExpandDirection)])
    {
        var text = ""
        var controls: [(Range<Int>, ExpandDirection)] = []
        func add(_ label: String, _ direction: ExpandDirection) {
            let start = text.count
            text += label
            controls.append((start..<text.count, direction))
            text += "    "
        }
        let step = min(DiffContent.expandStep, gap.hidden)
        if gap.canExpandDown { add("↓ \(step)", .down) }
        if gap.canExpandUp { add("↑ \(step)", .up) }
        add(
            gap.hidden == 1
                ? String(localized: "Show 1 more line", bundle: .module)
                : String(localized: "Show all \(gap.hidden) lines", bundle: .module), .all)
        return (text, controls)
    }
}
