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
        let left = removed.map(tokenize)
        let right = added.map(tokenize)
        for (i, j) in pairs(left, right) {
            guard let (a, b) = changes(left[i], right[j]) else { continue }
            result.removed[i] = a
            result.added[j] = b
        }
        return result
    }

    struct Token: Equatable {
        var text: Substring
        var start: Int
        var count: Int
    }

    /// Words, runs of whitespace, and every other character on its own.
    static func tokenize(_ line: String) -> [Token] {
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
            tokens.append(Token(text: line[index..<end], start: offset, count: count))
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
        var score = Array(
            repeating: Array(repeating: 0.0, count: right.count + 1), count: left.count + 1)
        var similarity = Array(
            repeating: Array(repeating: 0.0, count: right.count), count: left.count)
        for i in left.indices {
            for j in right.indices { similarity[i][j] = Self.similarity(left[i], right[j]) }
        }
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

    /// Characters in common tokens over all characters, ignoring whitespace-only tokens.
    static func similarity(_ left: [Token], _ right: [Token]) -> Double {
        let total =
            left.reduce(0) { $0 + weight($1) } + right.reduce(0) { $0 + weight($1) }
        guard total > 0, let common = commonTokens(left, right) else { return 0 }
        let shared = common.reduce(0) { $0 + weight(left[$1.0]) }
        return Double(2 * shared) / Double(total)
    }

    private static func weight(_ token: Token) -> Int {
        token.text.allSatisfy(\.isWhitespace) ? 0 : token.count
    }

    /// Index pairs of the longest common token subsequence; nil when a line is too long.
    static func commonTokens(_ left: [Token], _ right: [Token]) -> [(Int, Int)]? {
        guard left.count <= maximumTokens, right.count <= maximumTokens else { return nil }
        let width = right.count + 1
        var table = [Int](repeating: 0, count: (left.count + 1) * width)
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                table[i * width + j] =
                    left[i].text == right[j].text
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var (i, j) = (0, 0)
        while i < left.count, j < right.count {
            if left[i].text == right[j].text {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
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
