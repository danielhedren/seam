import Foundation

/// Which threads a `seam threads` or `seam wait` call is about (SPEC §13).
public struct ThreadScope: Sendable {
    /// One worktree's path, or nil for every worktree of the repo.
    public var worktree: String?
    public var includesResolved: Bool
    /// Only threads with activity at or after this time, resolved ones too, since resolving is
    /// activity. At, not after: a write racing the read behind the last "as of" comes back
    /// rather than being missed.
    public var since: Date?

    public init(worktree: String?, includesResolved: Bool = false, since: Date? = nil) {
        self.worktree = worktree
        self.includesResolved = includesResolved
        self.since = since
    }

    public func contains(_ thread: ReviewThread) -> Bool {
        (worktree == nil || thread.worktree == worktree)
            && (includesResolved || since != nil || !thread.isResolved)
            && (since.map { thread.lastActivity >= $0 } ?? true)
    }
}

/// What changed in a scope between two reads of the store.
public struct ThreadChanges: Equatable, Sendable {
    /// New threads and threads with any change, in store order.
    public var changed: [ReviewThread]
    public var deleted: [String]

    public var isEmpty: Bool { changed.isEmpty && deleted.isEmpty }

    public init(changed: [ReviewThread] = [], deleted: [String] = []) {
        self.changed = changed
        self.deleted = deleted
    }

    /// Resolved threads count here whatever the scope says: being resolved is a change.
    public static func between(
        _ old: [ReviewThread], _ new: [ReviewThread], worktree: String?
    ) -> ThreadChanges {
        let inScope = { (thread: ReviewThread) in worktree == nil || thread.worktree == worktree }
        let before = Dictionary(
            old.filter(inScope).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = new.filter(inScope)
        let ids = Set(after.map(\.id))
        return ThreadChanges(
            changed: after.filter { before[$0.id] != $0 },
            deleted: old.filter(inScope).map(\.id).filter { !ids.contains($0) })
    }
}

/// `seam wait`: returns once threads in the scope change, or nil when the timeout passes first.
public enum ThreadWait {
    /// `events` fires when the store's folder changes, and each one rereads the store; subscribe
    /// before calling, so nothing between the caller's last read and this one is lost. With a
    /// `since`, threads already active since then come back at once. `asOf` is when the read that
    /// found the changes began: the next call's `since`, which then leaves out what this one saw.
    public static func next<Events: AsyncSequence & Sendable, C: Clock<Duration>>(
        in scope: ThreadScope, read: @escaping @Sendable () throws(ThreadError) -> [ReviewThread],
        events: Events, clock: C, timeout: Duration?,
        now: @escaping @Sendable () -> Date = { .now }
    ) async throws -> (changes: ThreadChanges, asOf: Date)? where Events.Element == [String] {
        let startedAt = now()
        let start = try read()
        if scope.since != nil {
            let recent = start.filter(scope.contains)
            if !recent.isEmpty { return (ThreadChanges(changed: recent), startedAt) }
        }
        return try await withThrowingTaskGroup(of: (ThreadChanges, Date)?.self) { group in
            group.addTask {
                for try await _ in events {
                    let readAt = now()
                    let changes = ThreadChanges.between(start, try read(), worktree: scope.worktree)
                    if !changes.isEmpty { return (changes, readAt) }
                }
                return nil
            }
            if let timeout {
                group.addTask {
                    try await clock.sleep(for: timeout)
                    return nil
                }
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}
