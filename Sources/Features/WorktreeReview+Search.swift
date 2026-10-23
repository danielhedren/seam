import Foundation
import GitKit
import SeamCore

/// What the file list's column shows (SPEC §7.3.1).
enum Navigator: Equatable, Sendable {
    case files
    case search
}

enum Narrowing: Equatable {
    case filter(String)
    case search(TextQuery)
}

/// The search's results per diff and query, worked out once rather than on every redraw.
final class SearchCache {
    struct Key: Equatable {
        var diffVersion: Int
        var query: TextQuery
    }

    var key: Key?
    var result: ReviewSearch.Result?
}

extension WorktreeReview {
    /// Search shows a query, so the diff narrows to its results and highlights them.
    var isSearching: Bool { navigator == .search && !appliedSearch.isEmpty }

    var searchIsInvalid: Bool { !appliedSearch.isEmpty && appliedSearch.matcher() == nil }

    /// Nil without a query, a pattern that compiles or a diff.
    var searchResult: ReviewSearch.Result? {
        let key = SearchCache.Key(diffVersion: diffVersion, query: appliedSearch)
        if searchCache.key == key { return searchCache.result }
        let result = diff.flatMap { diff in
            appliedSearch.matcher().map { ReviewSearch.search($0, in: diff) }
        }
        searchCache.key = key
        searchCache.result = result
        return result
    }

    static let foldedLineCount = 20

    func isFolded(_ file: ReviewSearch.File) -> Bool {
        let path = diff?.files[file.index].diff.path ?? ""
        return (file.lines.count > Self.foldedLineCount) != searchFoldToggles.contains(path)
    }

    func toggleFold(_ path: String) {
        if searchFoldToggles.remove(path) == nil { searchFoldToggles.insert(path) }
    }

    var searchRows: [SearchRow] {
        guard let result = searchResult, let files = diff?.files else { return [] }
        return SearchRow.rows(result, files: files, flat: flatFileList, isFolded: isFolded)
    }

    /// Picking a result: a file scrolls the diff to it, a line also makes its match current,
    /// opening the file first if it's collapsed.
    func pick(_ row: SearchRow, controller: DiffController) {
        selectedSearchRow = row.id
        switch row.kind {
        case .heading: return
        case .file(let file):
            currentFile = file.path
            controller.scroll(toFile: file.path)
        case .line(let path, let line):
            if collapsed.contains(path) { toggleCollapsed(path) }
            currentFile = path
            controller.showMatch(
                inFile: path, line: line.number, isOld: line.kind == .removed, occurrence: 0)
        }
    }
}

/// One row of the search results (SPEC §7.3.1): folders as in the file tree, matching files, and
/// under each file its matching lines. Rows carry what they show: SwiftUI can still draw a row
/// from the previous result while the new one is in place.
struct SearchRow: Equatable, Identifiable {
    struct File: Equatable {
        var path: String
        var status: FileStatus
        /// In the row's name, which is the end of the path.
        var nameRanges: [Range<Int>]
        var lineMatchCount: Int
        var hasLines: Bool
        var isFolded: Bool
    }

    enum Kind: Equatable {
        /// A folder, or the "Generated" heading.
        case heading
        case file(File)
        case line(path: String, ReviewSearch.Line)
    }

    var id: String
    var name: String
    var depth: Int
    var kind: Kind

    var path: String? {
        switch kind {
        case .heading: nil
        case .file(let file): file.path
        case .line(let path, _): path
        }
    }

    static func rows(
        _ result: ReviewSearch.Result, files: [ReviewFile], flat: Bool,
        isFolded: (ReviewSearch.File) -> Bool
    ) -> [SearchRow] {
        let found = Dictionary(
            result.files.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let tree = FileTree.rows(
            files.map(\.diff.path), flat: flat,
            generated: Set(files.indices.filter { files[$0].isGenerated }), showsGenerated: true,
            only: Set(found.keys))
        var rows: [SearchRow] = []
        for row in tree {
            guard case .file(let index) = row.kind, let match = found[index] else {
                rows.append(SearchRow(id: row.id, name: row.name, depth: row.depth, kind: .heading))
                continue
            }
            let diff = files[index].diff
            let folded = isFolded(match)
            let file = File(
                path: diff.path, status: diff.status,
                nameRanges: SearchSnippet.name(row.name, path: diff.path, match.pathRanges),
                lineMatchCount: match.lineMatchCount, hasLines: !match.lines.isEmpty,
                isFolded: folded)
            rows.append(SearchRow(id: row.id, name: row.name, depth: row.depth, kind: .file(file)))
            guard !folded else { continue }
            rows += match.lines.enumerated().map {
                SearchRow(
                    id: "\(row.id)\u{0}\($0)", name: "", depth: row.depth + 1,
                    kind: .line(path: diff.path, $1))
            }
        }
        return rows
    }
}

/// A result line as the list shows it: without its indent, and cut so the first match shows.
enum SearchSnippet {
    static let lead = 12

    static func make(_ text: String, _ ranges: [Range<Int>]) -> (text: String, ranges: [Range<Int>])
    {
        let characters = Array(text)
        var start = characters.prefix { $0 == " " || $0 == "\t" }.count
        var prefix = ""
        if let first = ranges.first?.lowerBound, first - start > 2 * lead {
            start = first - lead
            prefix = "…"
        }
        let shift = start - prefix.count
        let shown = prefix + String(characters[min(start, characters.count)...])
        let moved = ranges.compactMap { range -> Range<Int>? in
            let lower = max(range.lowerBound - shift, prefix.count)
            let upper = range.upperBound - shift
            return lower < upper ? lower..<upper : nil
        }
        return (shown, moved)
    }

    /// A file row's name is the end of its path, so the path's ranges move to it.
    static func name(_ name: String, path: String, _ ranges: [Range<Int>]) -> [Range<Int>] {
        let offset = path.count - name.count
        return ranges.compactMap { range in
            let lower = max(range.lowerBound - offset, 0)
            let upper = range.upperBound - offset
            return lower < upper ? lower..<upper : nil
        }
    }
}
