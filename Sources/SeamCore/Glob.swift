/// Path globs for settings: `*` and `?` stay within one path segment, `**` crosses segments.
public struct Glob: Sendable, Hashable {
    public let pattern: String
    private let tokens: [Token]

    private enum Token: Hashable {
        case literal(Character)
        case anyInSegment
        case anyAcrossSegments
        case oneCharacter
    }

    public init(_ pattern: String) {
        self.pattern = pattern
        var tokens: [Token] = []
        var characters = Array(pattern)[...]
        while let character = characters.popFirst() {
            switch character {
            case "*" where characters.first == "*":
                characters.removeFirst()
                // `**/` also matches zero directories.
                if characters.first == "/" { characters.removeFirst() }
                tokens.append(.anyAcrossSegments)
            case "*": tokens.append(.anyInSegment)
            case "?": tokens.append(.oneCharacter)
            default: tokens.append(.literal(character))
            }
        }
        self.tokens = tokens
    }

    public func matches(_ path: String) -> Bool {
        Self.match(tokens[...], Array(path)[...])
    }

    private static func match(_ tokens: ArraySlice<Token>, _ text: ArraySlice<Character>) -> Bool {
        guard let token = tokens.first else { return text.isEmpty }
        let rest = tokens.dropFirst()
        switch token {
        case .literal(let character):
            return text.first == character && match(rest, text.dropFirst())
        case .oneCharacter:
            guard let first = text.first, first != "/" else { return false }
            return match(rest, text.dropFirst())
        case .anyInSegment, .anyAcrossSegments:
            var remaining = text
            while true {
                if match(rest, remaining) { return true }
                guard let first = remaining.first else { return false }
                if token == .anyInSegment && first == "/" { return false }
                remaining = remaining.dropFirst()
            }
        }
    }
}
