import CryptoKit
import Foundation
import SeamCore
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSharp
import TreeSitterDockerfile
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterRust
import TreeSitterSQL
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterXML
import TreeSitterYAML
import os

/// The v1 grammars of SPEC §8.4.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case csharp, typescript, tsx, javascript, json, yaml, markdown, xml, swift, rust, bash, sql
    case toml, dockerfile

    /// By file name; nil means plain text.
    public static func detect(path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "dockerfile" || name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile")
            || name == "containerfile"
        {
            return .dockerfile
        }
        switch (name as NSString).pathExtension {
        case "cs", "csx": return .csharp
        case "ts", "mts", "cts": return .typescript
        case "tsx": return .tsx
        case "js", "mjs", "cjs", "jsx": return .javascript
        case "json", "jsonc": return .json
        case "yml", "yaml": return .yaml
        case "md", "markdown": return .markdown
        case "xml", "csproj", "fsproj", "props", "targets", "xaml", "resx", "plist", "svg":
            return .xml
        case "swift": return .swift
        case "rs": return .rust
        case "sh", "bash", "zsh": return .bash
        case "sql": return .sql
        case "toml": return .toml
        default: return nil
        }
    }

    var language: Language {
        let pointer: UnsafeRawPointer =
            switch self {
            case .csharp: tree_sitter_c_sharp()
            case .typescript: tree_sitter_typescript()
            case .tsx: tree_sitter_tsx()
            case .javascript: tree_sitter_javascript()
            case .json: tree_sitter_json()
            case .yaml: tree_sitter_yaml()
            case .markdown: tree_sitter_markdown()
            case .xml: tree_sitter_xml()
            case .swift: tree_sitter_swift()
            case .rust: tree_sitter_rust()
            case .bash: tree_sitter_bash()
            case .sql: tree_sitter_sql()
            case .toml: tree_sitter_toml()
            case .dockerfile: tree_sitter_dockerfile()
            }
        return Language(language: OpaquePointer(pointer))
    }
}

/// Parses whole files and maps the highlight query's captures onto lines (SPEC §8.4). Queries
/// compile once per language; a query that fails to compile leaves that language plain.
public actor SyntaxHighlighter {
    private var queries: [SyntaxLanguage: Query?] = [:]
    /// Results by language and content hash, so unchanged files aren't parsed again on reload.
    private var cache: [String: [[SyntaxSpan]]] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 400
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Highlighting")
    private let signposter = OSSignposter(
        subsystem: "com.danielhedren.seam", category: "Highlighting")

    public init() {}

    /// Spans per line of `text`, or nil when the language can't be highlighted.
    public func highlight(_ text: String, as language: SyntaxLanguage) -> [[SyntaxSpan]]? {
        let key =
            language.rawValue + ":"
            + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = cache[key] { return cached }
        guard let lines = parse(text, as: language) else { return nil }
        cache[key] = lines
        cacheOrder.append(key)
        if cacheOrder.count > cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        return lines
    }

    private func parse(_ text: String, as language: SyntaxLanguage) -> [[SyntaxSpan]]? {
        let interval = signposter.beginInterval("highlight", "\(language.rawValue)")
        defer { signposter.endInterval("highlight", interval) }
        guard let query = query(for: language) else { return nil }
        let parser = Parser()
        do {
            try parser.setLanguage(language.language)
        } catch {
            logger.error("grammar \(language.rawValue, privacy: .public) rejected: \(error)")
            return nil
        }
        guard let tree = parser.parse(text) else { return nil }
        let ranges = query.execute(in: tree).resolve(with: .init(string: text)).highlights()
        return Self.lines(
            text,
            ranges.compactMap { range in
                Self.token(range.nameComponents).map { (range.range, $0) }
            })
    }

    private func query(for language: SyntaxLanguage) -> Query? {
        if let cached = queries[language] { return cached }
        var query: Query?
        do {
            guard
                let url = Bundle.module.url(
                    forResource: language.rawValue, withExtension: "scm", subdirectory: "Queries")
            else { throw CocoaError(.fileNoSuchFile) }
            query = try Query(language: language.language, data: try Data(contentsOf: url))
        } catch {
            logger.error("query for \(language.rawValue, privacy: .public) failed: \(error)")
        }
        queries[language] = query
        return query
    }

    /// Capture names are dotted (`function.method`, `keyword.return`); the first part decides,
    /// with a few exceptions where a more specific name means something else.
    static func token(_ components: [String]) -> SyntaxToken? {
        guard let first = components.first else { return nil }
        let name = components.joined(separator: ".")
        switch name {
        case "variable.builtin", "constant.builtin", "boolean": return .constant
        case "text.title", "markup.heading": return .heading
        case "text.literal", "markup.raw", "text.uri", "markup.link.url": return .string
        default: break
        }
        switch first {
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass",
            "type.qualifier":
            return .keyword
        case "string", "character": return .string
        case "comment": return .comment
        case "number", "float": return .number
        case "constant", "escape": return .constant
        case "type", "constructor", "namespace", "module": return .type
        case "function", "method": return .function
        case "property", "field": return .property
        case "attribute", "annotation": return .attribute
        case "tag": return .tag
        case "operator": return .operator
        case "punctuation", "delimiter": return .punctuation
        case "markup", "text":
            return components.contains("heading") || components.contains("title") ? .heading : nil
        default: return nil
        }
    }

    /// Paints UTF-16 ranges onto the text, inner ranges over outer ones and the first of equal
    /// ranges winning, then reads the paint back as per-line character runs.
    static func lines(_ text: String, _ ranges: [(NSRange, SyntaxToken)]) -> [[SyntaxSpan]] {
        let length = text.utf16.count
        var paint = [SyntaxToken?](repeating: nil, count: length)
        var seen = Set<NSRange>()
        let ordered = ranges.enumerated().sorted { lhs, rhs in
            lhs.element.0.length != rhs.element.0.length
                ? lhs.element.0.length > rhs.element.0.length : lhs.offset < rhs.offset
        }
        for (_, (range, token)) in ordered where !seen.contains(range) {
            seen.insert(range)
            let lower = max(range.location, 0)
            let upper = min(range.location + range.length, length)
            guard lower < upper else { continue }
            for index in lower..<upper { paint[index] = token }
        }

        var lines: [[SyntaxSpan]] = [[]]
        var column = 0
        var unit = 0
        var run: (start: Int, token: SyntaxToken)?
        func close() {
            if let current = run, column > current.start {
                lines[lines.count - 1].append(
                    SyntaxSpan(range: current.start..<column, token: current.token))
            }
            run = nil
        }
        for character in text {
            let width = character.utf16.count
            if character == "\n" || character == "\r\n" {
                close()
                lines.append([])
                column = 0
                unit += width
                continue
            }
            let token = unit < length ? paint[unit] : nil
            if token != run?.token {
                close()
                if let token { run = (column, token) }
            }
            column += 1
            unit += width
        }
        close()
        // Matches TextLines: "\r\n" is one Character, so hasSuffix("\n") misses CRLF text.
        if text.utf8.last == UInt8(ascii: "\n") { lines.removeLast() }
        return lines
    }
}
