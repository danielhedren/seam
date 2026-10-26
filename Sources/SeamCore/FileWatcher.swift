import Foundation

public protocol FileWatcher: Sendable {
    /// Batches of absolute paths that changed under `directories`, until the stream is dropped.
    func events(for directories: [URL]) -> AsyncStream<[String]>
}

#if canImport(CoreServices)
    public typealias SystemFileWatcher = FSEventsWatcher
#else
    public typealias SystemFileWatcher = InotifyWatcher
#endif

#if canImport(CoreServices)
    import CoreServices

    public struct FSEventsWatcher: FileWatcher {
        private let latency: TimeInterval

        public init(latency: TimeInterval = 0.05) {
            self.latency = latency
        }

        public func events(for directories: [URL]) -> AsyncStream<[String]> {
            AsyncStream { continuation in
                let sink = Sink(continuation)
                var context = FSEventStreamContext(
                    version: 0, info: Unmanaged.passRetained(sink).toOpaque(), retain: nil,
                    release: { info in
                        if let info { Unmanaged<Sink>.fromOpaque(info).release() }
                    }, copyDescription: nil)
                let flags = FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                        | kFSEventStreamCreateFlagNoDefer)
                guard
                    let stream = FSEventStreamCreate(
                        nil, Self.callback, &context, directories.map(\.path) as CFArray,
                        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
                else {
                    continuation.finish()
                    return
                }
                let handle = StreamHandle(stream)
                FSEventStreamSetDispatchQueue(
                    stream, DispatchQueue(label: "com.danielhedren.seam.fsevents"))
                FSEventStreamStart(stream)
                continuation.onTermination = { _ in handle.stop() }
            }
        }

        private static let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]
            sink.continuation.yield(array ?? [])
        }

        private final class Sink: Sendable {
            let continuation: AsyncStream<[String]>.Continuation
            init(_ continuation: AsyncStream<[String]>.Continuation) {
                self.continuation = continuation
            }
        }

        // FSEventStreamRef is not Sendable; it is only stopped once, from onTermination.
        private final class StreamHandle: @unchecked Sendable {
            private let stream: FSEventStreamRef
            init(_ stream: FSEventStreamRef) { self.stream = stream }

            func stop() {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
    }
#endif
