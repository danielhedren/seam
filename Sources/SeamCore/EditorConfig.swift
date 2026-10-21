import Foundation

/// Tab widths from a repository's root `.editorconfig` (SPEC §12). Only what the diff needs:
/// `tab_width`, or `indent_size` when that's a number. Nested `.editorconfig` files aren't read.
public struct EditorConfig: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        var patterns: [String]
        var tabWidth: Int?
    }

    var sections: [Section] = []

    public init(_ text: String) {
        var current: Section?
        var indentSize: Int?
        func close() {
            if var section = current {
                section.tabWidth = section.tabWidth ?? indentSize
                sections.append(section)
            }
            indentSize = nil
        }
        for raw in TextLines.split(text) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                close()
                current = Section(patterns: Self.expand(String(line.dropFirst().dropLast())))
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            guard parts.count == 2, current != nil else { continue }
            switch parts[0] {
            case "tab_width": current?.tabWidth = Int(parts[1])
            case "indent_size": indentSize = Int(parts[1])
            default: break
            }
        }
        close()
    }

    /// The last matching section with a width wins, as in EditorConfig itself.
    public func tabWidth(for path: String) -> Int? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return sections.last { section in
            section.tabWidth != nil
                && section.patterns.contains { pattern in
                    pattern.contains("/")
                        ? Glob(pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern)
                            .matches(path)
                        : Glob(pattern).matches(name)
                }
        }?.tabWidth
    }

    /// `*.{js,ts}` → `*.js`, `*.ts`. One level of braces, which covers real configs.
    static func expand(_ pattern: String) -> [String] {
        guard let open = pattern.firstIndex(of: "{"),
            let close = pattern[open...].firstIndex(of: "}")
        else { return [pattern] }
        let prefix = pattern[..<open]
        let suffix = pattern[pattern.index(after: close)...]
        return pattern[pattern.index(after: open)..<close].split(separator: ",").map {
            String(prefix + $0 + suffix)
        }
    }
}
