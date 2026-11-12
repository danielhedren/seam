import SeamCore

/// Go › Back and Forward (SPEC §7.4.1): every jump remembers where the reader was, per review.
extension RepoSession {
    func recordJump() {
        guard let id = selectedID, let place = diff.anchor else { return }
        jumpHistories[id, default: JumpHistory()].record(place)
    }

    private func isShown(_ path: String) -> Bool {
        selected?.diff?.files.contains { $0.diff.path == path } == true
    }

    package var canGoBack: Bool {
        selectedID.flatMap { jumpHistories[$0] }?.canGoBack(has: isShown) == true
    }

    package var canGoForward: Bool {
        selectedID.flatMap { jumpHistories[$0] }?.canGoForward(has: isShown) == true
    }

    package func goBack() {
        guard let id = selectedID else { return }
        let place = jumpHistories[id]?.goBack(from: diff.anchor, has: isShown)
        if let place { show(place) }
    }

    package func goForward() {
        guard let id = selectedID else { return }
        let place = jumpHistories[id]?.goForward(from: diff.anchor, has: isShown)
        if let place { show(place) }
    }

    private func show(_ place: ScrollAnchor) {
        guard let review = selected else { return }
        if review.collapsed.contains(place.path) { review.toggleCollapsed(place.path) }
        review.currentFile = place.path
        diff.restore(place)
    }
}
