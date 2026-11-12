import SeamCore

/// Outlines: the definitions a file's change touches, under its header (SPEC §7.4).
extension RepoSession {
    /// A row scrolls to where that definition's change starts, opening a collapsed file.
    package func openOutline(_ path: String, _ entry: OutlineEntry) {
        guard let review = selected else { return }
        if review.collapsed.contains(path) { toggleCollapsed(path) }
        diff.scroll(toLine: entry.line, inFile: path, side: entry.isOldSide ? .old : .new)
    }

    /// `⇧O`: the current file's outline, flipped from View › Show Outlines.
    package func toggleOutline(_ path: String? = nil) {
        guard let review = selected, let path = path ?? review.currentFile else { return }
        review.toggleOutline(path)
    }
}
