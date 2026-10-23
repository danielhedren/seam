import Foundation
import GitKit

/// What find and search look for (SPEC §7.3.1, §8.5): plain text ignoring case and diacritics
/// unless asked otherwise, or a regular expression.
public struct TextQuery: Equatable, Hashable, Sendable {
    public var text: String
    public var matchesCase: Bool
    public var isRegex: Bool

    public init(_ text: String = "", matchesCase: Bool = false, isRegex: Bool = false) {
        self.text = text
        self.matchesCase = matchesCase
        self.isRegex = isRegex
    }

    public var isEmpty: Bool { text.isEmpty }

    /// Nil for an empty query or a pattern that doesn't compile.
    public func matcher() -> TextMatcher? {
        guard !text.isEmpty else { return nil }
        guard isRegex else { return TextMatcher(kind: .text(text, matchesCase: matchesCase)) }
        guard
            let regex = try? NSRegularExpression(
                pattern: text, options: matchesCase ? [] : [.caseInsensitive])
        else { return nil }
        return TextMatcher(kind: .regex(regex))
    }
}

public struct TextMatcher {
    fileprivate enum Kind {
        case text(String, matchesCase: Bool)
        case regex(NSRegularExpression)
    }

    fileprivate let kind: Kind

    /// Every non-empty occurrence in `text`, as character offsets.
    public func ranges(in text: String) -> [Range<Int>] {
        var found: [Range<String.Index>] = []
        switch kind {
        case .text(let query, let matchesCase):
            let options: String.CompareOptions =
                matchesCase ? [] : [.caseInsensitive, .diacriticInsensitive]
            var start = text.startIndex
            while let range = text.range(of: query, options: options, range: start..<text.endIndex)
            {
                found.append(range)
                start = range.upperBound
            }
        case .regex(let regex):
            for result in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(result.range, in: text), !range.isEmpty { found.append(range) }
            }
        }
        return found.map {
            let lower = text.distance(from: text.startIndex, to: $0.lowerBound)
            return lower..<lower + text.distance(from: $0.lowerBound, to: $0.upperBound)
        }
    }
}

/// Search in the review's diff (SPEC §7.3.1): paths, and the lines of every hunk.
public enum ReviewSearch {
    public struct Line: Equatable, Sendable {
        public var kind: DiffLine.Kind
        /// The old line number for a removed line, the new one otherwise.
        public var number: Int
        public var text: String
        public var ranges: [Range<Int>]
    }

    public struct File: Equatable, Sendable {
        /// Index into the searched diff's files.
        public var index: Int
        public var pathRanges: [Range<Int>]
        public var lines: [Line]

        public var lineMatchCount: Int { lines.reduce(0) { $0 + $1.ranges.count } }
    }

    public struct Result: Equatable, Sendable {
        public var files: [File]
        /// Lines stopped at `limit`, so later files and lines are missing.
        public var isTruncated: Bool

        public var matchCount: Int { files.reduce(0) { $0 + $1.lineMatchCount } }
    }

    public static let limit = 1_000

    /// Files in the diff's order, each with its matching lines in hunk order.
    public static func search(
        _ matcher: TextMatcher, in diff: ReviewDiff, limit: Int = limit
    ) -> Result {
        var files: [File] = []
        var lineCount = 0
        var isTruncated = false
        for (index, file) in diff.files.enumerated() {
            var lines: [Line] = []
            search: for hunk in file.diff.hunks {
                for line in hunk.lines {
                    let ranges = matcher.ranges(in: line.text)
                    guard !ranges.isEmpty else { continue }
                    guard lineCount < limit else {
                        isTruncated = true
                        break search
                    }
                    let number =
                        line.kind == .removed ? line.oldNumber : line.newNumber ?? line.oldNumber
                    lines.append(
                        Line(kind: line.kind, number: number ?? 0, text: line.text, ranges: ranges))
                    lineCount += 1
                }
            }
            let pathRanges = matcher.ranges(in: file.diff.path)
            if !lines.isEmpty || !pathRanges.isEmpty {
                files.append(File(index: index, pathRanges: pathRanges, lines: lines))
            }
            if isTruncated { break }
        }
        return Result(files: files, isTruncated: isTruncated)
    }
}
