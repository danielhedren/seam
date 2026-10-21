import Highlighting
import SeamCore

/// Highlights a review's files, the one being read first (SPEC §8.4). Results publish after that
/// file and then in batches, since each publish rebuilds the diff's rows.
struct HighlightPass {
    static let batchSize = 25

    let files: [ReviewFile]
    let contents: [String: FileContents]
    let first: String?
    let highlighter: SyntaxHighlighter

    /// Stops between files once its task is cancelled.
    func run(publish: @MainActor ([String: FileSyntax]) -> Void) async {
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
                    result.old = await highlighter.highlight(text, as: language)
                }
                if let text = texts.new, let language = SyntaxLanguage.detect(path: path) {
                    result.new = await highlighter.highlight(text, as: language)
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
