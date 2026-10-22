import Foundation

public enum PatchParser {
    /// Parses `git diff` patch output produced with `--src-prefix=a/ --dst-prefix=b/`.
    public static func parse(_ data: Data) throws(GitError) -> [FileDiff] {
        let lines = splitLines(data)
        var files: [FileDiff] = []
        var index = 0
        while index < lines.count {
            guard lines[index].starts(with: diffGitPrefix) else {
                index += 1
                continue
            }
            let (file, next) = try parseFile(lines, at: index)
            files.append(file)
            index = next
        }
        return files
    }

    private static let diffGitPrefix = "diff --git ".utf8

    private static func splitLines(_ data: Data) -> [ArraySlice<UInt8>] {
        let bytes = Array(data)
        var lines = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private static func parseFile(
        _ lines: [ArraySlice<UInt8>], at start: Int
    ) throws(GitError) -> (FileDiff, Int) {
        let header = HeaderPaths(lines[start].dropFirst(diffGitPrefix.count))
        var meta = Metadata()
        var index = start + 1
        var hunks: [Hunk] = []

        while index < lines.count, !lines[index].starts(with: diffGitPrefix) {
            let line = lines[index]
            if line.starts(with: "@@ ".utf8) {
                let (hunk, next) = try parseHunk(lines, at: index)
                hunks.append(hunk)
                index = next
                continue
            }
            meta.read(line)
            index += 1
        }

        var file = FileDiff(
            oldPath: meta.oldPath ?? header?.old,
            newPath: meta.newPath ?? header?.new,
            status: meta.status
        )
        if meta.isAdded { file.oldPath = nil }
        if meta.isDeleted { file.newPath = nil }
        guard file.oldPath != nil || file.newPath != nil else {
            throw .unexpectedOutput("diff header without paths: \(text(lines[start]))")
        }
        file.oldMode = meta.oldMode
        file.newMode = meta.newMode
        file.oldBlob = meta.oldBlob
        file.newBlob = meta.newBlob
        file.isBinary = meta.isBinary
        file.hunks = hunks
        return (file, index)
    }

    private static func parseHunk(
        _ lines: [ArraySlice<UInt8>], at start: Int
    ) throws(GitError) -> (Hunk, Int) {
        guard var hunk = parseHunkHeader(text(lines[start])) else {
            throw .unexpectedOutput("bad hunk header: \(text(lines[start]))")
        }
        var oldLeft = hunk.oldCount
        var newLeft = hunk.newCount
        var oldNumber = hunk.oldStart
        var newNumber = hunk.newStart
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            if line.first == UInt8(ascii: "\\") {
                if !hunk.lines.isEmpty { hunk.lines[hunk.lines.count - 1].noNewlineAtEnd = true }
                index += 1
                continue
            }
            if oldLeft == 0 && newLeft == 0 { break }
            let body = text(line.dropFirst())
            switch line.first {
            case UInt8(ascii: "+"):
                hunk.lines.append(
                    DiffLine(kind: .added, text: body, oldNumber: nil, newNumber: newNumber))
                newNumber += 1
                newLeft -= 1
            case UInt8(ascii: "-"):
                hunk.lines.append(
                    DiffLine(kind: .removed, text: body, oldNumber: oldNumber, newNumber: nil))
                oldNumber += 1
                oldLeft -= 1
            case UInt8(ascii: " "), nil:
                hunk.lines.append(
                    DiffLine(kind: .context, text: body, oldNumber: oldNumber, newNumber: newNumber)
                )
                oldNumber += 1
                newNumber += 1
                oldLeft -= 1
                newLeft -= 1
            default:
                throw .unexpectedOutput("unexpected hunk line: \(text(line))")
            }
            index += 1
        }
        guard oldLeft <= 0, newLeft <= 0 else {
            throw .unexpectedOutput("truncated hunk at line \(start + 1)")
        }
        return (hunk, index)
    }

    /// `@@ -a[,b] +c[,d] @@[ section]`
    static func parseHunkHeader(_ line: String) -> Hunk? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 4 || (parts.count == 3 && parts[0] == "@@"),
            parts[0] == "@@", parts[1].hasPrefix("-"), parts[2].hasPrefix("+")
        else { return nil }
        guard let old = range(parts[1].dropFirst()), let new = range(parts[2].dropFirst()) else {
            return nil
        }
        var section = ""
        if parts.count == 4 {
            let rest = parts[3]
            guard rest.hasPrefix("@@") else { return nil }
            section = String(rest.dropFirst(2).drop { $0 == " " })
        }
        return Hunk(
            oldStart: old.0, oldCount: old.1, newStart: new.0, newCount: new.1, section: section)
    }

    private static func range(_ field: Substring) -> (Int, Int)? {
        let pieces = field.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(pieces[0]) else { return nil }
        if pieces.count == 1 { return (start, 1) }
        guard pieces.count == 2, let count = Int(pieces[1]) else { return nil }
        return (start, count)
    }

    fileprivate static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

/// Extended header lines between `diff --git` and the first hunk.
private struct Metadata {
    var oldPath: String?
    var newPath: String?
    var oldMode: String?
    var newMode: String?
    var oldBlob: String?
    var newBlob: String?
    var isAdded = false
    var isDeleted = false
    var isBinary = false
    var renameSimilarity: Int?
    var copySimilarity: Int?
    var similarity = 100

    var status: FileStatus {
        if isAdded { return .added }
        if isDeleted { return .deleted }
        if renameSimilarity != nil { return .renamed(similarity: similarity) }
        if copySimilarity != nil { return .copied(similarity: similarity) }
        return .modified
    }

    mutating func read(_ line: ArraySlice<UInt8>) {
        let string = PatchParser.text(line)
        if let value = field(line, "--- ") {
            if let path = Self.path(value, prefix: "a/") { oldPath = path }
        } else if let value = field(line, "+++ ") {
            if let path = Self.path(value, prefix: "b/") { newPath = path }
        } else if let value = field(line, "rename from ") {
            oldPath = CQuote.unquote(value)
            renameSimilarity = similarity
        } else if let value = field(line, "rename to ") {
            newPath = CQuote.unquote(value)
            renameSimilarity = similarity
        } else if let value = field(line, "copy from ") {
            oldPath = CQuote.unquote(value)
            copySimilarity = similarity
        } else if let value = field(line, "copy to ") {
            newPath = CQuote.unquote(value)
            copySimilarity = similarity
        } else if string.hasPrefix("similarity index "), let percent = Self.percent(string) {
            similarity = percent
        } else if string.hasPrefix("new file mode ") {
            isAdded = true
            newMode = String(string.dropFirst("new file mode ".count))
        } else if string.hasPrefix("deleted file mode ") {
            isDeleted = true
            oldMode = String(string.dropFirst("deleted file mode ".count))
        } else if string.hasPrefix("old mode ") {
            oldMode = String(string.dropFirst("old mode ".count))
        } else if string.hasPrefix("new mode ") {
            newMode = String(string.dropFirst("new mode ".count))
        } else if string.hasPrefix("index ") {
            readIndex(string.dropFirst("index ".count))
        } else if string.hasPrefix("Binary files ") || string == "GIT binary patch" {
            isBinary = true
        }
    }

    private mutating func readIndex(_ value: Substring) {
        let parts = value.split(separator: " ")
        guard let range = parts.first else { return }
        let blobs = range.split(separator: ".", omittingEmptySubsequences: true)
        if blobs.count == 2 {
            oldBlob = String(blobs[0])
            newBlob = String(blobs[1])
        }
        if parts.count == 2 {
            oldMode = oldMode ?? String(parts[1])
            newMode = newMode ?? String(parts[1])
        }
    }

    private func field(_ line: ArraySlice<UInt8>, _ prefix: String) -> ArraySlice<UInt8>? {
        guard line.starts(with: prefix.utf8) else { return nil }
        return line.dropFirst(prefix.utf8.count)
    }

    /// Path from a `---`/`+++` line. Git appends a tab when the name contains a space.
    private static func path(_ value: ArraySlice<UInt8>, prefix: String) -> String? {
        var value = value
        if value.last == UInt8(ascii: "\t") { value = value.dropLast() }
        guard let decoded = CQuote.unquote(value), decoded != "/dev/null" else { return nil }
        return decoded.hasPrefix(prefix) ? String(decoded.dropFirst(prefix.count)) : decoded
    }

    private static func percent(_ line: String) -> Int? {
        Int(line.split(separator: " ").last?.dropLast() ?? "")
    }
}

/// Paths from the `diff --git a/X b/Y` line, used only when no other header names them
/// (binary files and mode-only changes). Unquoted names are ambiguous when they contain
/// spaces, so an unquoted pair is split where both halves are equal.
private struct HeaderPaths {
    var old: String
    var new: String

    init?(_ rest: ArraySlice<UInt8>) {
        if rest.first == UInt8(ascii: "\"") {
            guard let (first, end) = CQuote.parse(rest, from: rest.startIndex),
                end < rest.endIndex, rest[end] == UInt8(ascii: " "),
                let second = CQuote.unquote(rest[(end + 1)...])
            else { return nil }
            self.init(old: first, new: second)
            return
        }
        if let quote = rest.firstRange(of: " \"b/".utf8) {
            guard let second = CQuote.unquote(rest[(quote.lowerBound + 1)...]) else { return nil }
            self.init(old: String(decoding: rest[..<quote.lowerBound], as: UTF8.self), new: second)
            return
        }
        let count = rest.count
        guard count >= 5, (count - 1) % 2 == 0 else { return nil }
        let half = (count - 1) / 2
        let first = rest.prefix(half)
        let second = rest.suffix(half)
        guard rest[rest.startIndex + half] == UInt8(ascii: " "),
            first.dropFirst(2).elementsEqual(second.dropFirst(2))
        else { return nil }
        self.init(
            old: String(decoding: first, as: UTF8.self),
            new: String(decoding: second, as: UTF8.self))
    }

    private init(old: String, new: String) {
        self.old = old.hasPrefix("a/") ? String(old.dropFirst(2)) : old
        self.new = new.hasPrefix("b/") ? String(new.dropFirst(2)) : new
    }
}
