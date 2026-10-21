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

/// Spans per line of each side of a file; a nil side isn't highlighted (yet).
public struct FileSyntax: Equatable, Sendable {
    public var old: [[SyntaxSpan]]?
    public var new: [[SyntaxSpan]]?

    public init(old: [[SyntaxSpan]]? = nil, new: [[SyntaxSpan]]? = nil) {
        self.old = old
        self.new = new
    }
}
