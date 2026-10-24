import GitKit

/// A file changed since it was marked viewed, shown as the change from the text the reader saw
/// to the text there now (SPEC §7.4). Diffed here rather than by git, because the version seen
/// was often only ever in the working tree, never a git object.
public enum SinceViewed {
    static let context = 3

    private struct Line: Hashable {
        var text: Substring
        var noNewlineAtEnd: Bool
    }

    /// `file` with its hunks replaced by the change from `old` to `new`.
    public static func diff(_ file: FileDiff, from old: String, to new: String) -> FileDiff {
        var diff = file
        diff.oldPath = file.newPath
        diff.status = .modified
        diff.hunks = hunks(from: old, to: new)
        return diff
    }

    static func hunks(from old: String, to new: String) -> [Hunk] {
        let before = lines(old)
        let after = lines(new)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in after.difference(from: before) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var script: [DiffLine] = []
        var i = 0
        var j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                script.append(line(.removed, before[i], old: i + 1, new: nil))
                i += 1
            } else if j < after.count, inserted.contains(j) {
                script.append(line(.added, after[j], old: nil, new: j + 1))
                j += 1
            } else {
                guard i < before.count, j < after.count else { break }
                script.append(line(.context, after[j], old: i + 1, new: j + 1))
                i += 1
                j += 1
            }
        }
        return cut(script)
    }

    /// The changed lines with `context` lines around them, runs that touch merged into one hunk.
    private static func cut(_ script: [DiffLine]) -> [Hunk] {
        var ranges: [ClosedRange<Int>] = []
        for index in script.indices where script[index].kind != .context {
            let range = max(0, index - context)...min(script.count - 1, index + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...range.upperBound
            } else {
                ranges.append(range)
            }
        }
        return ranges.map { range in
            let lines = Array(script[range])
            let before = script[..<range.lowerBound]
            // An empty side starts after the last line before it, as git writes it.
            let oldStart =
                lines.lazy.compactMap(\.oldNumber).first
                ?? before.count { $0.oldNumber != nil }
            let newStart =
                lines.lazy.compactMap(\.newNumber).first
                ?? before.count { $0.newNumber != nil }
            var hunk = Hunk(
                oldStart: oldStart, oldCount: lines.count { $0.oldNumber != nil },
                newStart: newStart, newCount: lines.count { $0.newNumber != nil }, section: "")
            hunk.lines = lines
            return hunk
        }
    }

    private static func lines(_ text: String) -> [Line] {
        let split = TextLines.split(text)
        let endsWithNewline = text.utf8.last == UInt8(ascii: "\n")
        return split.enumerated().map { offset, text in
            Line(text: text, noNewlineAtEnd: !endsWithNewline && offset == split.count - 1)
        }
    }

    private static func line(_ kind: DiffLine.Kind, _ line: Line, old: Int?, new: Int?)
        -> DiffLine
    {
        var diffLine = DiffLine(kind: kind, text: String(line.text), oldNumber: old, newNumber: new)
        diffLine.noNewlineAtEnd = line.noNewlineAtEnd
        return diffLine
    }
}
