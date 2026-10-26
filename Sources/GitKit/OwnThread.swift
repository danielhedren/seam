import Foundation

/// Runs blocking work on a thread of its own. On the concurrency pool, a few pipe readers
/// waiting for EOF can hold every thread, and the writer that would end them never runs.
func onOwnThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread { continuation.resume(returning: body()) }.start()
    }
}
