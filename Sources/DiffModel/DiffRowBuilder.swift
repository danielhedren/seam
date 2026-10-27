import Foundation
import GitKit
import SeamCore

package enum DiffRowBuilder {
    /// Files without loaded `contents` get no gap rows, sizes or previews.
    package static func rows(for content: DiffContent) -> [DiffRow] {
        var rows: [DiffRow] = content.preamble.map { marker in
            marker.id == content.openThread
                ? .openThread(file: DiffRow.preamble, marker)
                : .thread(file: DiffRow.preamble, marker)
        }
        rows.reserveCapacity(content.review.files.reduce(0) { $0 + $1.diff.hunks.count * 8 + 1 })
        for index in content.review.files.indices {
            rows += self.rows(forFile: index, in: content)
        }
        return rows
    }

    /// One file's rows, from its header on; lets a collapse rebuild only that file.
    package static func rows(forFile index: Int, in content: DiffContent) -> [DiffRow] {
        let path = content.review.files[index].diff.path
        guard !content.collapsed.contains(path) else { return fileRows(index, in: content) }
        let rows = insertingThreads(
            content.threads[path] ?? [], into: fileRows(index, in: content), file: index,
            open: content.openThread)
        guard let draft = content.draft, draft.path == path else { return rows }
        return insertingDraft(draft, into: rows, file: index)
    }

    private static func fileRows(_ index: Int, in content: DiffContent) -> [DiffRow] {
        let file = content.review.files[index]
        var rows: [DiffRow] = []
        rows.append(.fileHeader(file: index))
        guard !content.collapsed.contains(file.diff.path) else { return rows }
        let fileContents = content.contents[file.diff.path]
        let tabWidth = content.tabWidths[file.diff.path] ?? content.tabWidth
        if let notice = notice(for: file, contents: fileContents) {
            rows.append(.notice(file: index, text: notice))
            if fileContents?.oldImage != nil || fileContents?.newImage != nil {
                rows.append(.image(file: index))
            }
            return rows
        }
        let lines =
            file.diff.newPath == nil ? nil : fileContents?.new.map(TextLines.split)
        let fileExpansions = content.expansions[file.diff.path] ?? [:]
        let lookup = SyntaxLookup(
            syntax: content.syntax[file.diff.path], tabWidth: tabWidth,
            showsReturns: content.showsReturns)
        var next = (old: 1, new: 1)
        /// The rows for a gap, or nil when the file's text isn't loaded.
        @discardableResult
        func gap(_ number: Int, until end: Int) -> [DiffRow]? {
            guard let lines else { return nil }
            // max: a file that changed on disk since the diff can be shorter than its hunks.
            let gapRows = gapRows(
                file: index, gap: number, newRange: next.new..<max(end, next.new),
                oldOffset: next.old - next.new, lines: lines,
                expansion: fileExpansions[number] ?? GapExpansion(), mode: content.mode,
                lookup: lookup, isFirst: number == 0,
                isLast: number == file.diff.hunks.count)
            rows += gapRows
            return gapRows
        }
        for (hunkIndex, hunk) in file.diff.hunks.enumerated() {
            let first = Self.first(hunk)
            let above = gap(hunkIndex, until: first.new)
            next = Self.next(hunk)
            rows.append(
                .hunkHeader(
                    file: index, hunk: hunkIndex,
                    style(header(hunk, lookup.syntax), above: above, isFirst: hunkIndex == 0)))
            let texts = hunk.lines.map {
                TabStops.expand($0.text, width: tabWidth, showsReturns: content.showsReturns)
            }
            let highlights = wordHighlights(hunk.lines, texts)
            let oldSyntax = hunk.lines.map { lookup.old($0.oldNumber, raw: $0.text) }
            let newSyntax = hunk.lines.map { lookup.new($0.newNumber, raw: $0.text) }
            switch content.mode {
            case .unified:
                for (offset, line) in hunk.lines.enumerated() {
                    rows.append(
                        .line(
                            file: index,
                            UnifiedLine(
                                old: line.oldNumber, new: line.newNumber, kind: line.kind,
                                text: texts[offset], noNewline: line.noNewlineAtEnd,
                                highlights: highlights[offset],
                                syntax: line.kind == .removed
                                    ? oldSyntax[offset] : newSyntax[offset])))
                }
            case .split:
                rows += splitRows(
                    hunk.lines, texts, highlights, file: index,
                    syntax: (oldSyntax, newSyntax))
            }
        }
        if let lines, !file.diff.hunks.isEmpty {
            gap(file.diff.hunks.count, until: lines.count + 1)
        }
        return rows
    }

    /// A fully shown gap runs straight into the hunk, so no header. Otherwise a name shows, and
    /// without one a thin band marks where line numbers jump, unless a gap row already does or the
    /// hunk is the first thing in the file.
    static func style(_ title: String, above: [DiffRow]?, isFirst: Bool) -> HunkHeaderStyle {
        let hasGapRow = above?.contains { if case .gap = $0 { true } else { false } } ?? false
        if let above, !above.isEmpty, !hasGapRow { return .hidden }
        if !title.isEmpty { return .titled(title) }
        return hasGapRow || isFirst ? .hidden : .separator
    }

    /// The definitions around the hunk's first change, from the syntax tree. Git's own section
    /// heading is a guess (the last line starting in column 0), which in most C# or Swift names
    /// the class or namespace rather than the method; the line ranges repeat the gutter.
    static func header(_ hunk: Hunk, _ syntax: FileSyntax?) -> String {
        guard let syntax, let change = hunk.lines.first(where: { $0.kind != .context }) else {
            return ""
        }
        let names =
            if change.kind == .removed, let number = change.oldNumber {
                SyntaxScope.names(around: number - 1, in: syntax.oldScopes)
            } else if let number = change.newNumber {
                SyntaxScope.names(around: number - 1, in: syntax.newScopes)
            } else {
                [String]()
            }
        return names.joined(separator: " › ")
    }

    static func notice(for file: ReviewFile, contents: FileContents? = nil) -> String? {
        if file.isDeferred { return String(localized: "Large file not loaded", bundle: .module) }
        if file.diff.isBinary {
            let sizes = [contents?.oldSize, contents?.newSize].map {
                $0.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            }
            return switch (sizes[0], sizes[1]) {
            case (let old?, let new?):
                String(localized: "Binary file, \(old) → \(new)", bundle: .module)
            case (nil, let new?): String(localized: "Binary file, \(new)", bundle: .module)
            case (let old?, nil): String(localized: "Binary file, \(old) deleted", bundle: .module)
            case (nil, nil): String(localized: "Binary file", bundle: .module)
            }
        }
        guard file.diff.hunks.isEmpty else { return nil }
        if let old = file.diff.oldMode, let new = file.diff.newMode, old != new,
            file.diff.status == .modified
        {
            return String(localized: "Mode changed from \(old) to \(new)", bundle: .module)
        }
        switch file.diff.status {
        case .renamed: return String(localized: "Renamed without changes", bundle: .module)
        case .copied: return String(localized: "Copied without changes", bundle: .module)
        case .added: return String(localized: "Empty file", bundle: .module)
        case .deleted: return String(localized: "Empty file deleted", bundle: .module)
        case .modified: return String(localized: "No content changes", bundle: .module)
        }
    }

    /// Word highlights per hunk line: each run of removed lines and the added lines after it form
    /// one change block for `IntraLineDiff`.
    static func wordHighlights(_ lines: [DiffLine], _ texts: [String]) -> [[Range<Int>]] {
        var result = [[Range<Int>]](repeating: [], count: lines.count)
        var index = 0
        while index < lines.count {
            guard lines[index].kind != .context else {
                index += 1
                continue
            }
            var removed: [Int] = []
            var added: [Int] = []
            while index < lines.count, lines[index].kind == .removed {
                removed.append(index)
                index += 1
            }
            while index < lines.count, lines[index].kind == .added {
                added.append(index)
                index += 1
            }
            let block = IntraLineDiff.highlights(
                removed: removed.map { texts[$0] }, added: added.map { texts[$0] })
            for (offset, line) in removed.enumerated() { result[line] = block.removed[offset] }
            for (offset, line) in added.enumerated() { result[line] = block.added[offset] }
        }
        return result
    }

    /// Runs of removed lines pair with the added lines that follow them, in order.
    static func splitRows(
        _ lines: [DiffLine], _ texts: [String], _ highlights: [[Range<Int>]], file: Int,
        syntax: (old: [[SyntaxSpan]], new: [[SyntaxSpan]])? = nil
    ) -> [DiffRow] {
        let oldSyntax = syntax?.old ?? Array(repeating: [], count: lines.count)
        let newSyntax = syntax?.new ?? Array(repeating: [], count: lines.count)
        var rows: [DiffRow] = []
        var removed: [SideLine] = []
        var added: [SideLine] = []

        func flush() {
            for offset in 0..<max(removed.count, added.count) {
                rows.append(
                    .split(
                        file: file, left: offset < removed.count ? removed[offset] : nil,
                        right: offset < added.count ? added[offset] : nil))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }

        for (offset, line) in lines.enumerated() {
            let text = texts[offset]
            switch line.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(
                    SideLine(
                        kind: .removed, number: line.oldNumber ?? 0, text: text,
                        noNewlineAtEnd: line.noNewlineAtEnd, highlights: highlights[offset],
                        syntax: oldSyntax[offset]))
            case .added:
                added.append(
                    SideLine(
                        kind: .added, number: line.newNumber ?? 0, text: text,
                        noNewlineAtEnd: line.noNewlineAtEnd, highlights: highlights[offset],
                        syntax: newSyntax[offset]))
            case .context:
                flush()
                rows.append(
                    .split(
                        file: file,
                        left: SideLine(
                            kind: .context, number: line.oldNumber ?? 0, text: text,
                            noNewlineAtEnd: line.noNewlineAtEnd, syntax: oldSyntax[offset]),
                        right: SideLine(
                            kind: .context, number: line.newNumber ?? 0, text: text,
                            noNewlineAtEnd: line.noNewlineAtEnd, syntax: newSyntax[offset])))
            }
        }
        flush()
        return rows
    }
}
