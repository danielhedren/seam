import GitKit

/// What happened to an outdated thread's lines (SPEC §7.7): the change from the file it was
/// written on to the file now, around those lines, and where they'd be now.
public struct ThreadSince: Equatable, Sendable {
    /// The hunks that touch the thread's lines, numbered old as then and new as now.
    public var hunks: [Hunk]
    /// The line now nearest to the thread's last line then, for placing its card.
    public var line: Int

    public init(hunks: [Hunk], line: Int) {
        self.hunks = hunks
        self.line = line
    }

    /// Nil when `then` doesn't hold the thread's lines, so it can't be the text it was written on.
    public static func change(of anchor: ThreadAnchor, from then: String, to now: String)
        -> ThreadSince?
    {
        let thenLines = TextLines.split(then)
        // Line endings don't count, as in placing (ThreadPlacer).
        func bare(_ line: some StringProtocol) -> Substring {
            Substring(line).last == "\r" ? Substring(line).dropLast() : Substring(line)
        }
        guard anchor.lines.upperBound <= thenLines.count,
            zip(thenLines[(anchor.lines.lowerBound - 1)..<anchor.lines.upperBound], anchor.text)
                .allSatisfy({ bare($0) == bare($1) })
        else { return nil }
        let script = SinceViewed.script(from: then, to: now)
        // The last line now up to the thread's last line then, so after whatever replaced it.
        var line = 0
        for entry in script {
            if let old = entry.oldNumber, old > anchor.lines.upperBound { break }
            if let new = entry.newNumber { line = new }
        }
        let hunks = SinceViewed.cut(script).filter { hunk in
            let old = hunk.oldStart...max(hunk.oldStart, hunk.oldStart + hunk.oldCount - 1)
            return old.overlaps(anchor.lines)
        }
        return ThreadSince(hunks: hunks, line: max(line, 1))
    }
}
