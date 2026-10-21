import Foundation
import Synchronization

/// A clock that only moves when a test calls `advance(by:)` (SPEC §10: no sleeps).
public final class ManualClock: Clock, Sendable {
    public struct Instant: InstantProtocol {
        var offset: Duration

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration { other.offset - offset }

        public static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
        var cancelled: Set<Int> = []
        var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }
    public var minimumResolution: Duration { .zero }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: [CheckedContinuation<Void, Never>]? = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return nil }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return Self.takeWatchers(&state)
                }
                guard let ready else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                for continuation in ready { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return Sleeper?.none
                }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    public func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for id in due.keys { state.sleepers.removeValue(forKey: id) }
            return due.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }

    /// Returns once at least `count` tasks are sleeping on this clock.
    public func sleepers(_ count: Int = 1) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                state.watchers.append((count, continuation))
                return Self.takeWatchers(&state)
            }
            for continuation in ready { continuation.resume() }
        }
    }

    private static func takeWatchers(_ state: inout State) -> [CheckedContinuation<Void, Never>] {
        let count = state.sleepers.count
        let ready = state.watchers.filter { $0.count <= count }.map(\.continuation)
        state.watchers.removeAll { $0.count <= count }
        return ready
    }
}
