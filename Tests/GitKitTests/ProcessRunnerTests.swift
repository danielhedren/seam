import Foundation
import Testing

@testable import GitKit

@Suite(.timeLimit(.minutes(1))) struct ProcessRunnerTests {
    private let root = URL(fileURLWithPath: "/")

    private func run(_ executable: String, _ arguments: [String] = [], input: Data? = nil)
        async throws -> ProcessResult
    {
        try await ProcessRunner.run(
            executable: URL(fileURLWithPath: executable), arguments: arguments, directory: root,
            environment: [:], input: input)
    }

    /// Larger than a pipe buffer, so input and output only get through when fed and drained
    /// concurrently.
    @Test func inputLargerThanAPipeBufferComesBackWhole() async throws {
        let input = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0) })
        let result = try await run("/bin/cat", input: input)
        #expect(result.status == 0)
        #expect(result.stdout == input)
    }

    /// More runs at once than the concurrency pool has threads. Each blocks on its pipes until
    /// its input is written, so if blocked readers held every pool thread, no writer would run.
    @Test func manyRunsFeedingInputAtOnceAllFinish() async throws {
        let input = Data(repeating: UInt8(ascii: "x"), count: 200_000)
        let runs = 4 * ProcessInfo.processInfo.activeProcessorCount
        let outputs = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<runs { group.addTask { try await run("/bin/cat", input: input).stdout } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outputs.count == runs)
        #expect(outputs.allSatisfy { $0 == input })
    }

    /// `seam -C ../other` makes a URL relative to the current folder.
    @Test func aRelativeFolderURLRunsInTheFolderItNames() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let folder = parent.appending(path: "worktree")
        let here = parent.appending(path: "here/")
        for directory in [folder, here] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: parent) }
        let relative = URL(fileURLWithPath: "../worktree", relativeTo: here)

        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/pwd"), arguments: ["-P"], directory: relative,
            environment: [:], input: nil)

        let real = try #require(realpath(folder.path, nil))
        defer { free(real) }
        #expect(String(decoding: result.stdout, as: UTF8.self) == String(cString: real) + "\n")
    }

    @Test func exitStatusAndStandardErrorAreReported() async throws {
        let result = try await run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
        #expect(result.status == 3)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "oops\n")
        #expect(result.stdout.isEmpty)
    }

    @Test func aFailingGitCommandCarriesItsStatusAndMessage() async throws {
        // Not the inherited environment: a commit hook's GIT_DIR would make any folder a repo.
        let git = CLIGitClient(environment: ["PATH": "/usr/bin:/bin"])
        let error = await #expect(throws: GitError.self) {
            try await git.run(["rev-parse", "--git-dir"], in: root)
        }
        guard case .nonZeroExit(let arguments, let status, let stderr) = error else {
            Issue.record("expected a non-zero exit, got \(String(describing: error))")
            return
        }
        #expect(arguments == ["rev-parse", "--git-dir"])
        #expect(status == 128)
        #expect(stderr.contains("not a git repository"))
    }

    /// git exits without reading its input, so the write hits a closed pipe. Unguarded, that
    /// raises SIGPIPE and kills the whole app (and this test process).
    @Test func aCommandThatIgnoresItsInputDoesNotKillTheProcess() async throws {
        let input = Data(repeating: UInt8(ascii: "x"), count: 8_000_000)
        let output = try await CLIGitClient().run(["version"], in: root, input: input)
        #expect(String(decoding: output, as: UTF8.self).hasPrefix("git version"))
    }
}
