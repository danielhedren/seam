/// Syntax token classes, shared by Highlighting (which produces them) and DiffView (which draws
/// them) so neither imports the other (SPEC §8.2).
public enum SyntaxToken: String, CaseIterable, Sendable {
    case keyword
    case string
    case comment
    case number
    case constant
    case type
    case function
    case property
    case attribute
    case tag
    case `operator`
    case punctuation
    case variable
    case heading
}

/// A highlighted run within one line, as character offsets into the line's raw text.
public struct SyntaxSpan: Equatable, Sendable {
    public var range: Range<Int>
    public var token: SyntaxToken

    public init(range: Range<Int>, token: SyntaxToken) {
        self.range = range
        self.token = token
    }
}

/// A named definition (type, function, method) and the zero-based lines it spans.
public struct SyntaxScope: Equatable, Sendable {
    public var lines: ClosedRange<Int>
    public var name: String

    public init(lines: ClosedRange<Int>, name: String) {
        self.lines = lines
        self.name = name
    }

    /// The names of the definitions around `line`, outermost first; `scopes` is in document
    /// order, so a definition comes before the ones nested in it.
    public static func names(around line: Int, in scopes: [SyntaxScope]) -> [String] {
        scopes.filter { $0.lines.contains(line) }.map(\.name)
    }
}

/// Spans per line of each side of a file, and its definitions; a nil side isn't highlighted (yet).
public struct FileSyntax: Equatable, Sendable {
    public var old: [[SyntaxSpan]]?
    public var new: [[SyntaxSpan]]?
    public var oldScopes: [SyntaxScope]
    public var newScopes: [SyntaxScope]

    public init(
        old: [[SyntaxSpan]]? = nil, new: [[SyntaxSpan]]? = nil, oldScopes: [SyntaxScope] = [],
        newScopes: [SyntaxScope] = []
    ) {
        self.old = old
        self.new = new
        self.oldScopes = oldScopes
        self.newScopes = newScopes
    }
}
