import GitKit

/// What happened to an outdated thread's lines (SPEC §7.7): the change from the file it was
/// written on to the file now, around those lines, and where they'd be now.
public struct ThreadSince: Equatable, Sendable {
    /// The change around the thread's lines, numbered old as then and new as now.
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
        let now = max(line, 1)
        return ThreadSince(hunks: excerpt(script, then: anchor.lines, now: now), line: now)
    }

    static let context = 2

    /// Only what's about the thread's lines: them and `context` lines around them as they were,
    /// and as many lines around where they are now. Changes further off belong to the diff Jump
    /// to Commit shows.
    static func excerpt(_ script: [DiffLine], then lines: ClosedRange<Int>, now line: Int)
        -> [Hunk]
    {
        let old = (lines.lowerBound - context)...(lines.upperBound + context)
        let new = (line - lines.count - context + 1)...(line + context)
        let window = script.filter { entry in
            entry.oldNumber.map(old.contains) ?? false || entry.newNumber.map(new.contains) ?? false
        }
        guard window.contains(where: { $0.kind != .context }) else { return [] }
        var hunk = Hunk(
            oldStart: window.lazy.compactMap(\.oldNumber).first ?? 0,
            oldCount: window.count { $0.oldNumber != nil },
            newStart: window.lazy.compactMap(\.newNumber).first ?? 0,
            newCount: window.count { $0.newNumber != nil }, section: "")
        hunk.lines = window
        return [hunk]
    }
}
