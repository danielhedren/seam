import Highlighting
import SeamCore

/// Highlights a review's files, the one being read first (SPEC §8.4). Results publish after that
/// file and then in batches, since each publish rebuilds the diff's rows.
package struct HighlightPass {
    static let batchSize = 25

    package let files: [ReviewFile]
    let contents: [String: FileContents]
    let first: String?
    let highlighter: SyntaxHighlighter

    /// Stops between files once its task is cancelled.
    package func run(publish: @MainActor ([String: FileSyntax]) -> Void) async {
        let ordered =
            files.filter { $0.diff.path == first } + files.filter { $0.diff.path != first }
        var pending: [String: FileSyntax] = [:]
        for (index, file) in ordered.enumerated() {
            guard !Task.isCancelled else { return }
            let path = file.diff.path
            if let texts = contents[path] {
                var result = FileSyntax()
                if let text = texts.old,
                    let language = SyntaxLanguage.detect(path: file.diff.oldPath ?? path)
                {
                    let highlighted = await highlighter.highlight(text, as: language)
                    result.old = highlighted?.lines
                    result.oldScopes = highlighted?.scopes ?? []
                }
                if let text = texts.new, let language = SyntaxLanguage.detect(path: path) {
                    let highlighted = await highlighter.highlight(text, as: language)
                    result.new = highlighted?.lines
                    result.newScopes = highlighted?.scopes ?? []
                }
                if result.old != nil || result.new != nil { pending[path] = result }
            }
            let isBoundary =
                index == 0 || index % Self.batchSize == Self.batchSize - 1
                || index == ordered.count - 1
            if isBoundary, !pending.isEmpty {
                guard !Task.isCancelled else { return }
                await publish(pending)
                pending = [:]
            }
        }
    }
}
