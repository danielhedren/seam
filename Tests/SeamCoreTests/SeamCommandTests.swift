import Foundation
import GitKit
import TestSupport
import Testing

@testable import SeamCore

/// SPEC §13 through the built `seam` itself: what an agent types and what it gets back, exit
/// statuses included, against a fixture repo and a scratch thread store.
@Suite(.timeLimit(.minutes(1)))
struct SeamCommandTests {
    private final class Here {}

    private struct Run {
        var status: Int32
        var output: String
        var errors: String
    }

    private let store = Scratch.path("seam-cli-threads")

    /// Built beside the test bundles by `swift build --build-tests`.
    private static var seam: URL {
        Bundle(for: Here.self).bundleURL.deletingLastPathComponent().appending(path: "seam")
    }

    private func seam(_ arguments: [String], in directory: URL) async throws -> Run {
        let process = Process()
        process.executableURL = Self.seam
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": FileManager.default.temporaryDirectory.path,
            "SEAM_THREAD_DIR": store.path, "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        // A termination handler, not waitUntilExit(), which can block a pool thread for good.
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        return Run(
            status: status, output: String(decoding: outData, as: UTF8.self),
            errors: String(decoding: errData, as: UTF8.self))
    }

    private func fixture() async throws -> FixtureRepo {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        return repo
    }

    @Test func anAgentOpensListsAnswersAndResolvesAThread() async throws {
        let repo = try await fixture()
        let opened = try await seam(
            ["comment", "a.txt:2", "Why two?", "--as", "claude"], in: repo.main)
        #expect(opened.status == 0)
        let id = try #require(opened.output.split(separator: "#").last?.prefix(8)).description

        let listed = try await seam(["threads"], in: repo.main)
        #expect(listed.status == 0)
        #expect(listed.output.contains("#\(id)  open  a.txt:2  opened by claude"))
        #expect(listed.output.contains("2 │ two"))

        #expect(
            try await seam(["reply", id, "Because.", "--as", "codex"], in: repo.main).status == 0)
        #expect(try await seam(["resolve", id], in: repo.main).status == 0)
        #expect(try await seam(["threads"], in: repo.main).output == "No open threads.\n")
        let all = try await seam(["threads", "--all"], in: repo.main)
        #expect(all.output.contains("#\(id)  resolved"))
        #expect(all.output.contains("  codex · ") && all.output.contains("    Because."))
    }

    /// The comment's line numbers are from when it was written; seam says where the lines are
    /// now, or that they're gone.
    @Test func threadsSayWhereTheirLinesAreNow() async throws {
        let repo = try await fixture()
        _ = try await seam(["comment", "a.txt:2", "Why two?"], in: repo.main)
        try repo.write("a.txt", "zero\none\ntwo\n")
        #expect(
            try await seam(["threads"], in: repo.main).output.contains(
                "  Now at a.txt:3: the lines moved since."))
        try repo.write("a.txt", "one\n")
        #expect(
            try await seam(["threads"], in: repo.main).output.contains(
                "  Outdated: these lines aren't in a.txt any more"))
    }

    /// An agent points the reviewer at something without asking for an answer: a note isn't
    /// open work, so it's listed only when asked for.
    @Test func anAgentsNoteIsntAnOpenThread() async throws {
        let repo = try await fixture()
        let left = try await seam(
            ["comment", "--note", "a.txt:1", "Kept for the old API.", "--as", "claude"],
            in: repo.main)
        #expect(left.output.hasPrefix("Left note #"))
        #expect(try await seam(["threads"], in: repo.main).output == "No open threads.\n")
        let listed = try await seam(["threads", "--notes"], in: repo.main)
        #expect(listed.output.contains("  note  a.txt:1  opened by claude"))
    }

    @Test func jsonIsTheThreadsAsStored() async throws {
        let repo = try await fixture()
        _ = try await seam(["comment", "a.txt:1", "Why one?", "--as", "claude"], in: repo.main)
        let listed = try await seam(["threads", "--json"], in: repo.main)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ThreadTime.decoding
        let threads = try decoder.decode([ReviewThread].self, from: Data(listed.output.utf8))
        #expect(threads.map(\.anchor.text) == [["one"]])
        #expect(threads.first?.comments.map(\.author) == ["claude"])
        let object = try #require(
            (try JSONSerialization.jsonObject(with: Data(listed.output.utf8)) as? [[String: Any]])?
                .first)
        #expect(object["source"] as? String == "seam")
        let placement = try #require(object["placement"] as? [String: Any])
        #expect(placement["state"] as? String == "lines")
        #expect(placement["lines"] as? [Int] == [1, 1])
    }

    @Test func mistakesSayWhatWentWrongWithTheRightStatus() async throws {
        let repo = try await fixture()
        let usage = try await seam(["comment", "a.txt", "no line"], in: repo.main)
        #expect(usage.status == 64)
        #expect(usage.errors.contains("Error: expected file:line or file:first-last"))

        let unknown = try await seam(["reply", "deadbeef", "Hi"], in: repo.main)
        #expect(unknown.status == 1)
        #expect(unknown.errors.contains("Error: no thread #deadbeef in this repository"))

        let outside = try await seam(["threads"], in: FileManager.default.temporaryDirectory)
        #expect(outside.status == 1)
        #expect(outside.errors.contains("is not in a git worktree"))

        let past = try await seam(["comment", "a.txt:9", "Where?"], in: repo.main)
        #expect(past.status == 1)
        #expect(past.errors.contains("has 2 lines on the new side"))
    }

    @Test func waitingWithNothingChangingEndsWithStatusTwo() async throws {
        let repo = try await fixture()
        let waited = try await seam(["wait", "--timeout", "1"], in: repo.main)
        #expect(waited.status == 2)
        #expect(waited.errors.contains("No thread changed within 1 second."))
    }

    /// A pull request's thread is listed with the command that answers it, and seam refuses to
    /// change it (SPEC §7.9).
    @Test func aGitHubThreadIsListedAndRefusedWithTheCommandThatAnswersIt() async throws {
        let repo = try await fixture()
        let repository = try await RepositoryService(git: repo.git).open(repo.main).0
        let github = GitHubThreads.threads(
            from: [
                GitHubReviewThread(
                    id: "PRRT_1", path: "a.txt", lines: 1...1,
                    comments: [
                        .init(
                            id: 7, author: "octocat", body: "Why one?", created: .now, url: "u",
                            diffHunk: "@@ -0,0 +1,2 @@\n+one\n+two")
                    ])
            ], worktree: repo.main.path,
            repo: GitHubRepo(host: "github.com", owner: "o", name: "a"), pullRequest: 12)
        try ThreadStore(directory: store).saveGitHubThreads(
            github, worktree: repo.main.path, read: .now, for: repository)

        let listed = try await seam(["threads"], in: repo.main)
        #expect(listed.output.contains("#gh-7  open  a.txt:1  opened by octocat on GitHub"))
        #expect(listed.output.contains("-F body=@reply.md"))
        let json = try await seam(["thread", "gh-7", "--json"], in: repo.main)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any])
        #expect(object["source"] as? String == "github")
        #expect((object["replyCommand"] as? String)?.hasSuffix("-F body=@reply.md") == true)
        #expect(object["readAt"] != nil)
        let refused = try await seam(["reply", "gh-7", "Because."], in: repo.main)
        #expect(refused.status == 1)
        #expect(refused.errors.contains("repos/o/a/pulls/12/comments/7/replies"))
    }
}
