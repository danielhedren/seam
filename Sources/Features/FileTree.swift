import Foundation

/// One visible row of the file list (SPEC §7.3).
struct FileListRow: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A directory, with single-child chains compacted into one name (`src/Orders.Service`).
        case directory(isExpanded: Bool)
        /// Index into the review's files.
        case file(Int)
    }

    var id: String
    var name: String
    var depth: Int
    var kind: Kind
}

enum FileTree {
    /// Rows for `paths`, as a tree grouped by directory or as a flat list. A non-empty `filter`
    /// keeps files whose path contains it, ignoring case, and shows their directories expanded.
    static func rows(
        _ paths: [String], flat: Bool = false, collapsed: Set<String> = [], filter: String = ""
    ) -> [FileListRow] {
        let matching = paths.indices.filter {
            filter.isEmpty || paths[$0].localizedCaseInsensitiveContains(filter)
        }
        if flat {
            return matching.map {
                FileListRow(id: paths[$0], name: paths[$0], depth: 0, kind: .file($0))
            }
        }
        let root = Node()
        for index in matching {
            var node = root
            let parts = paths[index].split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                node = node.child(part)
            }
            node.files.append((parts.last ?? paths[index], index))
        }
        var rows: [FileListRow] = []
        emit(root, prefix: "", depth: 0, collapsed: filter.isEmpty ? collapsed : [], into: &rows)
        return rows
    }

    private final class Node {
        var directories: [(String, Node)] = []
        var files: [(String, Int)] = []

        func child(_ name: String) -> Node {
            if let existing = directories.first(where: { $0.0 == name }) { return existing.1 }
            let node = Node()
            directories.append((name, node))
            return node
        }
    }

    private static func emit(
        _ node: Node, prefix: String, depth: Int, collapsed: Set<String>,
        into rows: inout [FileListRow]
    ) {
        for (name, child) in node.directories.sorted(by: { $0.0 < $1.0 }) {
            var label = name
            var current = child
            while current.files.isEmpty, current.directories.count == 1,
                let (next, grandchild) = current.directories.first
            {
                label += "/" + next
                current = grandchild
            }
            let id = prefix + label + "/"
            let isExpanded = !collapsed.contains(id)
            rows.append(
                FileListRow(
                    id: id, name: label, depth: depth, kind: .directory(isExpanded: isExpanded)))
            if isExpanded {
                emit(current, prefix: id, depth: depth + 1, collapsed: collapsed, into: &rows)
            }
        }
        for (name, index) in node.files.sorted(by: { $0.0 < $1.0 }) {
            rows.append(
                FileListRow(id: prefix + name, name: name, depth: depth, kind: .file(index)))
        }
    }
}

enum FuzzyMatch {
    /// A score for `query` as a subsequence of `candidate`, higher is better; nil when it isn't
    /// one. Consecutive characters and matches at word starts score more.
    static func score(_ query: String, in candidate: String) -> Int? {
        let query = Array(query.lowercased())
        let text = Array(candidate.lowercased())
        guard !query.isEmpty else { return 0 }
        var score = 0
        var position = 0
        var previous = -2
        for character in query {
            guard let found = text[position...].firstIndex(of: character) else { return nil }
            score += 1
            if found == previous + 1 { score += 5 }
            if found == 0 || "-_/. ".contains(text[found - 1]) { score += 3 }
            previous = found
            position = found + 1
        }
        return score - text.count / 10
    }
}
