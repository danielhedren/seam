/// Word-level highlights within changed lines (SPEC §7.4): removed and added lines of one change
/// block are paired by similarity, and each pair's differing tokens are marked. Ranges are
/// character offsets into the strings passed in.
public enum IntraLineDiff {
    public struct Result: Equatable, Sendable {
        public var removed: [[Range<Int>]]
        public var added: [[Range<Int>]]
    }

    /// Pairs below this similarity share too little for word highlights to help.
    static let minimumSimilarity = 0.5
    /// Larger blocks pair by position, and longer lines get no highlights, so cost stays bounded.
    static let maximumPairings = 400
    static let maximumTokens = 400

    public static func highlights(removed: [String], added: [String]) -> Result {
        var result = Result(
            removed: Array(repeating: [], count: removed.count),
            added: Array(repeating: [], count: added.count))
        guard !removed.isEmpty, !added.isEmpty else { return result }
        var interner = Interner()
        let left = removed.map { tokenize($0, &interner) }
        let right = added.map { tokenize($0, &interner) }
        for (i, j) in pairs(left, right) {
            guard let (a, b) = changes(left[i], right[j]) else { continue }
            result.removed[i] = a
            result.added[j] = b
        }
        return result
    }

    /// Tokens compare as small integers: one hash per token instead of one per comparison.
    struct Interner {
        private var ids: [Substring: Int] = [:]

        mutating func id(_ text: Substring) -> Int {
            if let id = ids[text] { return id }
            let id = ids.count
            ids[text] = id
            return id
        }
    }

    struct Token: Equatable {
        var id: Int
        var start: Int
        var count: Int
        /// Characters that count towards similarity; whitespace-only tokens count for nothing.
        var weight: Int
    }

    /// Words, runs of whitespace, and every other character on its own.
    static func tokenize(_ line: String, _ interner: inout Interner) -> [Token] {
        var tokens: [Token] = []
        var offset = 0
        var index = line.startIndex
        while index < line.endIndex {
            let first = line[index]
            var end = line.index(after: index)
            if isWord(first) {
                while end < line.endIndex, isWord(line[end]) { end = line.index(after: end) }
            } else if first.isWhitespace {
                while end < line.endIndex, line[end].isWhitespace { end = line.index(after: end) }
            }
            let count = line.distance(from: index, to: end)
            tokens.append(
                Token(
                    id: interner.id(line[index..<end]), start: offset, count: count,
                    weight: first.isWhitespace ? 0 : count))
            offset += count
            index = end
        }
        return tokens
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// In-order pairs maximising total similarity: an alignment over the two lists.
    static func pairs(_ left: [[Token]], _ right: [[Token]]) -> [(Int, Int)] {
        guard left.count * right.count <= maximumPairings else {
            return (0..<min(left.count, right.count)).map { ($0, $0) }
        }
        var table = Table()
        var similarity = Array(
            repeating: Array(repeating: 0.0, count: right.count), count: left.count)
        for i in left.indices {
            for j in right.indices { similarity[i][j] = Self.similarity(left[i], right[j], &table) }
        }
        var score = Array(
            repeating: Array(repeating: 0.0, count: right.count + 1), count: left.count + 1)
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                let paired =
                    similarity[i][j] >= minimumSimilarity
                    ? similarity[i][j] + score[i + 1][j + 1] : 0
                score[i][j] = max(paired, score[i + 1][j], score[i][j + 1])
            }
        }
        var result: [(Int, Int)] = []
        var (i, j) = (0, 0)
        while i < left.count, j < right.count {
            let value = similarity[i][j]
            if value >= minimumSimilarity, score[i][j] == value + score[i + 1][j + 1] {
                result.append((i, j))
                i += 1
                j += 1
            } else if score[i + 1][j] >= score[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }

    /// Reused across comparisons, so pairing allocates one buffer per block, not one per pair.
    struct Table {
        var values: [Int] = []

        /// `aligning` adds one per matched token, so equal-weight alignments prefer keeping
        /// whitespace in common; similarity uses the plain weights.
        mutating func fill(_ left: [Token], _ right: [Token], aligning: Bool = false) {
            let width = right.count + 1
            let size = (left.count + 1) * width
            if values.count < size { values = [Int](repeating: 0, count: size) }
            for j in 0...right.count { values[left.count * width + j] = 0 }
            for i in stride(from: left.count - 1, through: 0, by: -1) {
                values[i * width + right.count] = 0
                for j in stride(from: right.count - 1, through: 0, by: -1) {
                    values[i * width + j] =
                        left[i].id == right[j].id
                        ? values[(i + 1) * width + j + 1] + left[i].weight * (aligning ? 2 : 1)
                            + (aligning ? 1 : 0)
                        : max(values[(i + 1) * width + j], values[i * width + j + 1])
                }
            }
        }

        subscript(i: Int, j: Int, width width: Int) -> Int { values[i * width + j] }
    }

    /// Weighted characters in common over all weighted characters.
    static func similarity(_ left: [Token], _ right: [Token], _ table: inout Table) -> Double {
        let total = left.reduce(0) { $0 + $1.weight } + right.reduce(0) { $0 + $1.weight }
        guard total > 0, left.count <= maximumTokens, right.count <= maximumTokens else { return 0 }
        table.fill(left, right)
        return Double(2 * table[0, 0, width: right.count + 1]) / Double(total)
    }

    /// Index pairs of the heaviest common token subsequence; nil when a line is too long.
    static func commonTokens(_ left: [Token], _ right: [Token]) -> [(Int, Int)]? {
        guard left.count <= maximumTokens, right.count <= maximumTokens else { return nil }
        var table = Table()
        table.fill(left, right, aligning: true)
        let width = right.count + 1
        var pairs: [(Int, Int)] = []
        var (i, j) = (0, 0)
        while i < left.count, j < right.count {
            if left[i].id == right[j].id,
                table[i, j, width: width]
                    == table[i + 1, j + 1, width: width] + left[i].weight * 2 + 1
            {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1, j, width: width] >= table[i, j + 1, width: width] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// The character ranges of each side's tokens outside the common subsequence, merged.
    static func changes(_ left: [Token], _ right: [Token]) -> ([Range<Int>], [Range<Int>])? {
        guard let common = commonTokens(left, right) else { return nil }
        let keptLeft = Set(common.map(\.0))
        let keptRight = Set(common.map(\.1))
        return (ranges(left, keeping: keptLeft), ranges(right, keeping: keptRight))
    }

    private static func ranges(_ tokens: [Token], keeping kept: Set<Int>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for (index, token) in tokens.enumerated() where !kept.contains(index) {
            let range = token.start..<(token.start + token.count)
            if let last = ranges.last, last.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }
}
