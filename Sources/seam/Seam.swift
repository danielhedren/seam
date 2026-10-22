import AppKit
import ArgumentParser
import Foundation
import GitKit
import SeamCore

/// `seam`: opens a worktree in the app, and reads and writes review threads for agents
/// (SPEC §13). Thread commands work on the store directly, with or without the app running.
@main
struct Seam: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seam", abstract: "Review git worktrees in Seam.",
        subcommands: [
            Open.self, Threads.self, ShowThread.self, Reply.self, Comment.self, Resolve.self,
            Reopen.self,
        ],
        defaultSubcommand: Open.self)
}

struct Open: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open the repo containing a folder and select its worktree.")

    @Argument(help: "A folder in the worktree; the current one by default.")
    var path: String?

    @Option(help: "Compare the worktree with this ref instead of the detected parent.")
    var base: String?

    func run() throws {
        let folder = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
        guard let real = realpath(folder.path, nil) else {
            throw ValidationError("no such folder: \(folder.path)")
        }
        defer { free(real) }
        guard let url = SeamURL(path: String(cString: real), base: base).url else {
            throw ValidationError("can't build the URL")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments =
            Self.app.map { ["-a", $0.path, url.absoluteString] }
            ?? ["-b", "com.danielhedren.seam", url.absoluteString]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
    }

    /// The app this command was copied into: a build-directory copy and an installed one can
    /// coexist, and `open -b` would pick whichever LaunchServices prefers.
    static var app: URL? {
        // Not argv[0]: run from $PATH that's just "seam".
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let resources = executable.deletingLastPathComponent()
        guard resources.lastPathComponent == "Resources",
            resources.deletingLastPathComponent().lastPathComponent == "Contents"
        else { return nil }
        let app = resources.deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }
}

/// What every thread command shares: which worktree, and who is writing.
struct ThreadOptions: ParsableArguments {
    @Option(name: .customShort("C"), help: "Act on the worktree containing this folder.")
    var directory: String?

    @Option(name: .customLong("as"), help: "Sign as this name ($SEAM_AGENT, else \"agent\").")
    var author: String?

    var signature: String {
        author ?? ProcessInfo.processInfo.environment["SEAM_AGENT"].flatMap {
            $0.isEmpty ? nil : $0
        } ?? "agent"
    }

    func worktree() async throws -> (Repository, URL) {
        let folder = URL(
            fileURLWithPath: directory ?? FileManager.default.currentDirectoryPath,
            isDirectory: true)
        do {
            return try await RepositoryService(git: CLIGitClient()).open(folder)
        } catch {
            throw ValidationError("\(folder.path) is not in a git worktree")
        }
    }
}

struct Threads: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List this worktree's threads.")

    @OptionGroup var options: ThreadOptions
    @Flag(help: "Include resolved threads.") var all = false
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let (repository, worktree) = try await options.worktree()
        let threads = try threadStore().threads(for: repository).filter {
            $0.worktree == worktree.path && (all || !$0.isResolved)
        }
        if json {
            try printJSON(threads)
        } else if threads.isEmpty {
            print(all ? "No threads." : "No open threads.")
        } else {
            print(threads.map { ThreadText.format($0) }.joined(separator: "\n\n"))
        }
    }
}

struct ShowThread: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thread", abstract: "Show one thread with its comments.")

    @OptionGroup var options: ThreadOptions
    @Argument(help: "The thread's id, as `seam threads` prints it.") var id: String
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let (repository, _) = try await options.worktree()
        let id = id.trimmingPrefix("#")
        guard let thread = try threadStore().threads(for: repository).first(where: { $0.id == id })
        else { throw ThreadError.unknownThread(String(id)) }
        if json { try printJSON(thread) } else { print(ThreadText.format(thread)) }
    }
}

struct Reply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Answer a thread; a reply to a resolved thread reopens it.")

    @OptionGroup var options: ThreadOptions
    @Argument var id: String
    @Argument(help: "Markdown; quote it in the shell.") var text: String

    func run() async throws {
        let (repository, _) = try await options.worktree()
        let author = options.signature
        let id = String(id.trimmingPrefix("#"))
        try threadStore().update(repository) { threads throws(ThreadError) in
            try ThreadRules.reply(&threads, to: id, author: author, body: text, now: .now)
        }
        print("Replied to #\(id).")
    }
}

struct Comment: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a thread on lines of a file, as a reviewer.")

    @OptionGroup var options: ThreadOptions
    @Argument(help: "file:line or file:first-last, relative to the worktree or this folder.")
    var location: String
    @Flag(help: "The lines are on the old side: the base the diff starts from.") var old = false
    @Argument(help: "Markdown; quote it in the shell.") var text: String

    func run() async throws {
        let (repository, worktree) = try await options.worktree()
        guard let (path, lines) = ThreadText.location(location) else {
            throw ValidationError("expected file:line or file:first-last, got \(location)")
        }
        let relative = relativePath(path, in: worktree)
        let side: ThreadAnchor.Side = old ? .old : .new
        let file = TextLines.split(try await contents(of: relative, side: side, in: worktree))
        guard let anchor = ThreadAnchor(path: relative, side: side, lines: lines, in: file) else {
            throw ValidationError("\(relative) has \(file.count) lines")
        }
        let author = options.signature
        let thread = try threadStore().update(repository) { threads throws(ThreadError) in
            try ThreadRules.open(
                &threads, worktree: worktree.path, anchor: anchor, author: author, body: text,
                now: .now)
        }
        print("Opened #\(thread.id).")
    }

    /// Paths an agent types are usually from the worktree's root, but may be from where it is.
    private func relativePath(_ path: String, in worktree: URL) -> String {
        let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: path).standardizedFileURL.path
        let root = worktree.standardizedFileURL.path + "/"
        guard FileManager.default.fileExists(atPath: here), here.hasPrefix(root) else {
            return path
        }
        return String(here.dropFirst(root.count))
    }

    private func contents(of path: String, side: ThreadAnchor.Side, in worktree: URL)
        async throws -> String
    {
        switch side {
        case .new:
            guard
                let data = FileManager.default.contents(atPath: worktree.appending(path: path).path)
            else { throw ValidationError("no file \(path) in \(worktree.path)") }
            return String(decoding: data, as: UTF8.self)
        case .old:
            let git = CLIGitClient()
            let base = try await BaseDetector(git: git).detect(in: worktree).base
            return try await git.string(["show", "\(base):\(path)"], in: worktree)
        }
    }
}

struct Resolve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Resolve a thread you opened.")

    @OptionGroup var options: ThreadOptions
    @Argument var id: String

    func run() async throws { try await setResolved(true, id, options) }
}

struct Reopen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Reopen a thread you opened.")

    @OptionGroup var options: ThreadOptions
    @Argument var id: String

    func run() async throws { try await setResolved(false, id, options) }
}

private func setResolved(_ resolved: Bool, _ id: String, _ options: ThreadOptions) async throws {
    let (repository, _) = try await options.worktree()
    let author = options.signature
    let id = String(id.trimmingPrefix("#"))
    try threadStore().update(repository) { threads throws(ThreadError) in
        try ThreadRules.setResolved(resolved, &threads, id: id, by: author)
    }
    print(resolved ? "Resolved #\(id)." : "Reopened #\(id).")
}

/// `SEAM_THREAD_DIR` points the commands at another store, for trying them without touching
/// the app's.
private func threadStore() -> ThreadStore {
    guard let directory = ProcessInfo.processInfo.environment["SEAM_THREAD_DIR"], !directory.isEmpty
    else { return ThreadStore() }
    return ThreadStore(directory: URL(fileURLWithPath: directory, isDirectory: true))
}

private func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

extension ThreadError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknownThread(let id): "no thread #\(id) in this repository"
        case .notAuthor(let thread, let author):
            "only \(author), who opened #\(thread), can resolve or reopen it"
        case .emptyComment: "the comment is empty"
        case .unsupportedVersion(let version):
            "the thread store was written by a newer Seam (format \(version))"
        case .unreadable(let message): "can't read the thread store: \(message)"
        }
    }
}
