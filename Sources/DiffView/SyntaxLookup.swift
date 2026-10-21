import SeamCore

/// A file's syntax spans by line number, moved onto display columns where tabs were expanded.
struct SyntaxLookup {
    var syntax: FileSyntax?
    var tabWidth: Int

    func old(_ number: Int?, raw: String) -> [SyntaxSpan] { spans(syntax?.old, number, raw) }
    func new(_ number: Int?, raw: String) -> [SyntaxSpan] { spans(syntax?.new, number, raw) }

    private func spans(_ lines: [[SyntaxSpan]]?, _ number: Int?, _ raw: String) -> [SyntaxSpan] {
        guard let lines, let number, lines.indices.contains(number - 1) else { return [] }
        let spans = lines[number - 1]
        guard !spans.isEmpty, raw.contains("\t") else { return spans }
        var columns: [Int] = []
        var column = 0
        for character in raw {
            columns.append(column)
            column += character == "\t" ? tabWidth - column % tabWidth : 1
        }
        columns.append(column)
        return spans.map { span in
            let lower = columns[min(span.range.lowerBound, columns.count - 1)]
            let upper = columns[min(span.range.upperBound, columns.count - 1)]
            return SyntaxSpan(range: lower..<max(lower, upper), token: span.token)
        }
    }
}
