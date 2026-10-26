import Foundation

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
}

// Process is not Sendable; it is only touched again by terminate(), which Foundation allows from
// any thread.
private final class ProcessHandle: @unchecked Sendable {
    let process = Process()
}

enum ProcessRunner {
    #if !canImport(Darwin)
        /// Linux has no per-pipe flag, so SIGPIPE is ignored for the whole process, once.
        static let ignoreSIGPIPE: Void = { _ = signal(SIGPIPE, SIG_IGN) }()
    #endif

    static func run(
        executable: URL,
        arguments: [String],
        directory: URL,
        environment: [String: String],
        input: Data?
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let handle = ProcessHandle()
        let process = handle.process
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        // Process can't launch in a relative URL that starts with "..", as `seam -C ../x` makes.
        process.currentDirectoryURL = directory.absoluteURL
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exited.continuation.yield(process.terminationStatus)
            exited.continuation.finish()
        }

        return try await withTaskCancellationHandler {
            try process.run()
            // A cancel that lands before run() finds nothing running to terminate.
            if Task.isCancelled { process.terminate() }
            // Drain both pipes and feed stdin concurrently, or a full pipe buffer deadlocks git.
            async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
                .value
            async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
                .value
            async let wrote: Void = Task.detached {
                guard let input else { return }
                let writer = stdin.fileHandleForWriting
                // git may exit, or be terminated, before reading everything. A write to the closed
                // pipe would raise SIGPIPE and kill the app; this makes it fail with EPIPE.
                #if canImport(Darwin)
                    _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                #else
                    ProcessRunner.ignoreSIGPIPE
                #endif
                try? writer.write(contentsOf: input)
                try? writer.close()
            }.value
            var status: Int32 = -1
            for await code in exited.stream { status = code }
            await wrote
            let result = ProcessResult(status: status, stdout: await out, stderr: await err)
            try Task.checkCancellation()
            return result
        } onCancel: {
            if handle.process.isRunning { handle.process.terminate() }
        }
    }
}
