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
        process.currentDirectoryURL = directory
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
            // Drain both pipes and feed stdin concurrently, or a full pipe buffer deadlocks git.
            async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
                .value
            async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
                .value
            if let input {
                Task.detached {
                    let writer = stdin.fileHandleForWriting
                    try? writer.write(contentsOf: input)
                    try? writer.close()
                }
            }
            var status: Int32 = -1
            for await code in exited.stream { status = code }
            let result = ProcessResult(status: status, stdout: await out, stderr: await err)
            try Task.checkCancellation()
            return result
        } onCancel: {
            if handle.process.isRunning { handle.process.terminate() }
        }
    }
}
