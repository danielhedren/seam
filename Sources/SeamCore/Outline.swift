import Foundation
import GitKit

/// One definition a file's change touches, for its outline (SPEC §7.4).
public struct OutlineEntry: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case added, removed
        /// Its first line changed.
        case signature
        case body
    }

    public var change: Change
    /// The names around it, outermost first, ending with its own.
    public var path: [String]
    /// Where its change starts, one-based: its first changed line on the new side, or on the
    /// old side when only lines were removed from it. That line is always in the diff.
    public var line: Int
    public var isOldSide: Bool
    /// Its length in lines before and after, when it changed by half or more.
    public var lengths: (old: Int, new: Int)?

    public init(
        change: Change, path: [String], line: Int, isOldSide: Bool = false,
        lengths: (old: Int, new: Int)? = nil
    ) {
        self.change = change
        self.path = path
        self.line = line
        self.isOldSide = isOldSide
        self.lengths = lengths
    }

    public static func == (lhs: OutlineEntry, rhs: OutlineEntry) -> Bool {
        lhs.change == rhs.change && lhs.path == rhs.path && lhs.line == rhs.line
            && lhs.isOldSide == rhs.isOldSide && lhs.lengths?.old == rhs.lengths?.old
            && lhs.lengths?.new == rhs.lengths?.new
    }
}

/// The definitions a change touches (SPEC §7.4): each changed line counts for the innermost
/// definition around it; definitions are matched across the sides by their path of names, and
/// same-named ones by order.
public enum Outline {
    public static func entries(of diff: FileDiff, syntax: FileSyntax) -> [OutlineEntry] {
        let lines = diff.hunks.flatMap(\.lines)
        let added = Set(lines.compactMap { $0.kind == .added ? $0.newNumber.map { $0 - 1 } : nil })
        let removed = Set(
            lines.compactMap { $0.kind == .removed ? $0.oldNumber.map { $0 - 1 } : nil })
        let old = Side(syntax.oldScopes)
        let new = Side(syntax.newScopes)
        let newForOld = Dictionary(
            old.keys.indices.compactMap { index in new.index[old.keys[index]].map { (index, $0) } },
            uniquingKeysWith: { first, _ in first })
        let oldForNew = Dictionary(
            newForOld.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        var entries: [OutlineEntry] = []
        var seen = Set<String>()
        func add(_ entry: OutlineEntry, key: String) {
            guard seen.insert(key).inserted else { return }
            entries.append(entry)
        }
        func changed(new index: Int, old match: Int) {
            let newScope = new.scopes[index]
            let oldScope = old.scopes[match]
            let signature =
                added.contains(newScope.lines.lowerBound)
                || removed.contains(oldScope.lines.lowerBound)
            let (before, after) = (oldScope.lines.count, newScope.lines.count)
            let grew = max(before, after) * 2 >= min(before, after) * 3
            let firstAdded = added.filter(newScope.lines.contains).min()
            let firstRemoved = removed.filter(oldScope.lines.contains).min()
            add(
                OutlineEntry(
                    change: signature ? .signature : .body, path: new.paths[index],
                    line: (firstAdded ?? firstRemoved ?? newScope.lines.lowerBound) + 1,
                    isOldSide: firstAdded == nil && firstRemoved != nil,
                    lengths: grew ? (before, after) : nil),
                key: "~" + new.keys[index])
        }
        for index in Set(added.compactMap(new.innermost)).sorted() {
            if let match = oldForNew[index] {
                changed(new: index, old: match)
            } else {
                // An added method of an added type is the type's addition.
                let outermost = new.outermostUnmatched(index) { oldForNew[$0] == nil }
                add(
                    OutlineEntry(
                        change: .added, path: new.paths[outermost],
                        line: new.scopes[outermost].lines.lowerBound + 1),
                    key: "+" + new.keys[outermost])
            }
        }
        for index in Set(removed.compactMap(old.innermost)).sorted() {
            if let match = newForOld[index] {
                changed(new: match, old: index)
            } else {
                let outermost = old.outermostUnmatched(index) { newForOld[$0] == nil }
                add(
                    OutlineEntry(
                        change: .removed, path: old.paths[outermost],
                        line: old.scopes[outermost].lines.lowerBound + 1, isOldSide: true),
                    key: "-" + old.keys[outermost])
            }
        }
        return entries.sorted { $0.line < $1.line }
    }

    /// One side's definitions with their paths and the keys that match them to the other's.
    private struct Side {
        var scopes: [SyntaxScope]
        var paths: [[String]]
        var keys: [String]
        var index: [String: Int]
        /// The innermost definition at each line, or -1.
        private var innermostAt: [Int]

        /// One pass in document order, keeping the definitions still open: a definition's
        /// ancestors are exactly those around it.
        init(_ scopes: [SyntaxScope]) {
            self.scopes = scopes
            var open: [Int] = []
            var paths: [[String]] = []
            for scope in scopes {
                while let last = open.last, !Self.contains(scopes[last], scope) {
                    open.removeLast()
                }
                paths.append(open.map { scopes[$0].name } + [scope.name])
                open.append(paths.count - 1)
            }
            self.paths = paths
            var innermostAt = Array(
                repeating: -1, count: (scopes.map(\.lines.upperBound).max() ?? -1) + 1)
            for (index, scope) in scopes.enumerated() {
                for line in scope.lines { innermostAt[line] = index }
            }
            self.innermostAt = innermostAt
            var counts: [String: Int] = [:]
            keys = paths.map { path in
                let joined = path.joined(separator: "\u{1F}")
                counts[joined, default: 0] += 1
                return "\(joined)\u{1E}\(counts[joined] ?? 0)"
            }
            index = Dictionary(
                keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        }

        /// Scopes are in document order, so the last one around a line is the innermost.
        func innermost(_ line: Int) -> Int? {
            guard innermostAt.indices.contains(line), innermostAt[line] >= 0 else { return nil }
            return innermostAt[line]
        }

        private static func contains(_ outer: SyntaxScope, _ inner: SyntaxScope) -> Bool {
            outer.lines.lowerBound <= inner.lines.lowerBound
                && outer.lines.upperBound >= inner.lines.upperBound
        }

        func outermostUnmatched(_ index: Int, isUnmatched: (Int) -> Bool) -> Int {
            let scope = scopes[index]
            return scopes.indices.first { candidate in
                scopes[candidate].lines.lowerBound <= scope.lines.lowerBound
                    && scopes[candidate].lines.upperBound >= scope.lines.upperBound
                    && isUnmatched(candidate)
            } ?? index
        }
    }
}
