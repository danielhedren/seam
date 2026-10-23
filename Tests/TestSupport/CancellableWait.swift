import Synchronization

/// Suspends until `register`'s callback runs or the task is cancelled, so a test whose condition
/// never comes fails at its time limit instead of hanging the run.
public nonisolated(nonsending) func waitCancellably(
    _ register: (_ resume: @escaping @Sendable () -> Void) -> Void
) async {
    let slot = ContinuationSlot()
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            slot.set(continuation)
            if Task.isCancelled { slot.resume() }
            register { slot.resume() }
        }
    } onCancel: {
        slot.resume()
    }
}

private final class ContinuationSlot: Sendable {
    private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    /// Only the first call resumes.
    func resume() {
        continuation.withLock { slot in
            defer { slot = nil }
            return slot
        }?.resume()
    }
}
