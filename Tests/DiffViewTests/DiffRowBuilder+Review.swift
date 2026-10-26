import SeamCore

@testable import DiffModel
@testable import DiffView

extension DiffRowBuilder {
    /// The rows for `review` with the rest of `DiffContent` at its defaults.
    static func rows(
        for review: ReviewDiff, mode: DiffLayoutMode, collapsed: Set<String> = [],
        contents: [String: FileContents] = [:], expansions: [String: [Int: GapExpansion]] = [:],
        syntax: [String: FileSyntax] = [:]
    ) -> [DiffRow] {
        rows(
            for: DiffContent(
                review: review, mode: mode, collapsed: collapsed, contents: contents,
                expansions: expansions, syntax: syntax))
    }
}
