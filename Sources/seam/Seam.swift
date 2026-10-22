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
        commandName: "seam", abstract: "Review git worktrees in Seam, and answer review threads.",
        discussion: """
            Run seam in a worktree to open its repository in Seam with that worktree selected.

            The thread commands read and write the review comments left in Seam. They act on \
            the worktree containing the current folder (or -C <path>), work without the app \
            running, and sign what they write as --as <name>, else $SEAM_AGENT, else "agent". \
            Thread ids are as `seam threads` prints them, with or without the leading #.

            A typical round: `seam threads`, make the changes, then \
            `seam reply <id> "Done: ..." --as <name>` for each thread.
            """,
        subcommands: [Open.self],
        groupedSubcommands: [
            CommandGroup(
                name: "Review threads",
                subcommands: [
                    Threads.self, ShowThread.self, Wait.self, Comment.self, Reply.self,
                    Resolve.self, Reopen.self, Delete.self,
                ])
        ],
        defaultSubcommand: Open.self)
}

struct Open: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open the repository containing a folder in Seam and select its worktree.")

    @Argument(help: "A folder in the worktree; the current folder by default.")
    var path: String?

    @Option(
        help: ArgumentHelp(
            "Diff the worktree against this ref instead of the detected parent.",
            valueName: "ref"))
    var base: String?

    func run() throws {
        let folder = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath)
        guard let real = realpath(folder.path, nil) else {
            throw Failure("no such folder: \(folder.path)")
        }
        defer { free(real) }
        guard let url = SeamURL(path: String(cString: real), base: base).url else {
            throw Failure("can't build a seam:// URL for \(folder.path)")
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

/// Which worktree every thread command acts on.
struct ThreadOptions: ParsableArguments {
    @Option(
        name: .customShort("C"),
        help: ArgumentHelp(
            "Act on the worktree containing this folder, not the current one.", valueName: "path"))
    var directory: String?

    func worktree() async throws -> (Repository, URL) {
        let folder = URL(
            fileURLWithPath: directory ?? FileManager.default.currentDirectoryPath,
            isDirectory: true)
        do {
            return try await RepositoryService(git: CLIGitClient()).open(folder)
        } catch {
            throw Failure("\(folder.path) is not in a git worktree")
        }
    }
}

/// Who a comment is from. Commands that don't write a comment still accept `--as`, hidden, so
/// an agent that passes it everywhere isn't refused.
struct Signature: ParsableArguments {
    @Option(
        name: .customLong("as"),
        help: ArgumentHelp(
            "Sign the comment as this name; default $SEAM_AGENT, else \"agent\".",
            valueName: "name"))
    var author: String?

    var name: String {
        author ?? ProcessInfo.processInfo.environment["SEAM_AGENT"].flatMap {
            $0.isEmpty ? nil : $0
        } ?? "agent"
    }
}

struct Threads: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List this worktree's open threads.",
        discussion: """
            Each thread shows its id, status, file and lines, who opened it, the lines it is \
            on, and its comments, oldest first.
            """)

    @OptionGroup var options: ThreadOptions
    @OptionGroup(visibility: .hidden) var signature: Signature
    @Flag(help: "Include resolved threads.") var all = false
    @Flag(help: repoHelp) var repo = false
    @Option(help: sinceHelp, transform: parseTime) var since: Date?
    @Flag(help: jsonHelp) var json = false

    func run() async throws {
        let (repository, worktree) = try await options.worktree()
        let scope = ThreadScope(
            worktree: repo ? nil : worktree.path, includesResolved: all, since: since)
        let threads = try threadStore().threads(for: repository).filter(scope.contains)
        if json {
            try printJSON(threads)
        } else if threads.isEmpty {
            print(
                since.map { "No threads changed since \($0.formatted(.iso8601))." }
                    ?? (all ? "No threads." : "No open threads."))
        } else {
            print(
                threads.map { ThreadText.format($0, showsWorktree: repo) }.joined(separator: "\n\n")
            )
        }
    }
}

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Wait until threads change, then print what changed.",
        discussion: """
            Prints the threads that are new, replied to, resolved or reopened, and the ids of \
            deleted ones, then "As of <time>". Pass that time as --since to the next wait and \
            no change between the two is missed. Exits with status 2 when --timeout passes \
            first.
            """)

    @OptionGroup var options: ThreadOptions
    @OptionGroup(visibility: .hidden) var signature: Signature
    @Flag(help: repoHelp) var repo = false
    @Option(help: sinceHelp, transform: parseTime) var since: Date?
    @Option(help: ArgumentHelp("Give up after this many seconds.", valueName: "seconds"))
    var timeout: Int?
    @Flag(help: jsonHelp) var json = false

    private struct Output: Encodable {
        var asOf: Date
        var changed: [ReviewThread]
        var deleted: [String]
    }

    func run() async throws {
        let (repository, worktree) = try await options.worktree()
        let store = threadStore()
        try FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true)
        // Watching starts before the first read, so a write in between still wakes the wait.
        let events = FSEventsWatcher().events(for: [store.directory])
        guard
            let (changes, asOf) = try await ThreadWait.next(
                in: ThreadScope(worktree: repo ? nil : worktree.path, since: since),
                read: { () throws(ThreadError) in try store.threads(for: repository) },
                events: events, clock: ContinuousClock(), timeout: timeout.map { .seconds($0) })
        else {
            let seconds = timeout ?? 0
            FileHandle.standardError.write(
                Data("No thread changed within \(seconds) second\(seconds == 1 ? "" : "s").\n".utf8)
            )
            throw ExitCode(2)
        }
        if json {
            try printJSON(Output(asOf: asOf, changed: changes.changed, deleted: changes.deleted))
            return
        }
        var parts = changes.changed.map { ThreadText.format($0, showsWorktree: repo) }
        parts += changes.deleted.map { "#\($0) deleted" }
        parts.append("As of \(asOf.formatted(.iso8601))")
        print(parts.joined(separator: "\n\n"))
    }
}

private let sinceHelp = ArgumentHelp(
    "Only threads changed at or after this ISO 8601 time, as `seam wait` prints it.",
    valueName: "time")
private let repoHelp = ArgumentHelp("Every worktree of the repository, not just this one.")
private let jsonHelp = ArgumentHelp("Print JSON instead of text.")
private let textHelp = ArgumentHelp("The comment, in Markdown. Quote it for the shell.")
private let idHelp = ArgumentHelp("The thread's id, as `seam threads` prints it.")

private func parseTime(_ text: String) throws -> Date {
    do {
        return try Date(text, strategy: .iso8601)
    } catch {
        throw ValidationError("expected an ISO 8601 time such as 2026-10-22T18:30:00Z")
    }
}

struct ShowThread: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "thread", abstract: "Show one thread with all its comments.")

    @OptionGroup var options: ThreadOptions
    @OptionGroup(visibility: .hidden) var signature: Signature
    @Argument(help: idHelp) var id: String
    @Flag(help: jsonHelp) var json = false

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
        abstract: "Answer a thread. A reply to a resolved thread reopens it.")

    @OptionGroup var options: ThreadOptions
    @OptionGroup var signature: Signature
    @Argument(help: idHelp) var id: String
    @Argument(help: textHelp) var text: String

    func run() async throws {
        let (repository, _) = try await options.worktree()
        let author = signature.name
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
    @OptionGroup var signature: Signature
    @Argument(
        help: ArgumentHelp(
            "The file and lines, relative to the worktree or the current folder.",
            valueName: "file:line[-end]"))
    var location: String
    @Flag(help: "The lines are on the old side: the base the diff starts from.") var old = false
    @Argument(help: textHelp) var text: String

    func validate() throws {
        guard ThreadText.location(location) != nil else {
            throw ValidationError("expected file:line or file:first-last, got \(location)")
        }
    }

    func run() async throws {
        let (repository, worktree) = try await options.worktree()
        guard let (path, lines) = ThreadText.location(location) else { return }
        let relative = relativePath(path, in: worktree)
        let side: ThreadAnchor.Side = old ? .old : .new
        let file = TextLines.split(
            try await contents(of: relative, side: side, in: worktree, repository))
        guard let anchor = ThreadAnchor(path: relative, side: side, lines: lines, in: file) else {
            throw Failure(
                "\(relative) has \(file.count) lines on the \(old ? "old" : "new") side")
        }
        let author = signature.name
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

    private func contents(
        of path: String, side: ThreadAnchor.Side, in worktree: URL, _ repository: Repository
    ) async throws -> String {
        switch side {
        case .new:
            guard
                let data = FileManager.default.contents(atPath: worktree.appending(path: path).path)
            else { throw Failure("no file \(path) in \(worktree.path)") }
            return String(decoding: data, as: UTF8.self)
        case .old:
            let base = try await shownBase(of: worktree, in: repository)
            return try await CLIGitClient().string(["show", "\(base):\(path)"], in: worktree)
        }
    }

    /// The base the app shows for this worktree: detected with its settings, or the parent the
    /// reader picked for the branch.
    private func shownBase(of worktree: URL, in repository: Repository) async throws -> String {
        let git = CLIGitClient()
        let settings =
            UserDefaults(suiteName: AppChoices.defaultsDomain).map(AppChoices.detectionSettings)
            ?? DetectionSettings()
        let detection = try await BaseDetector(git: git, settings: settings).detect(in: worktree)
        let branch = try? await git.string(["symbolic-ref", "--quiet", "HEAD"], in: worktree)
        let override = branch.flatMap {
            AppChoices.baseOverride(
                branch: $0.trimmingCharacters(in: .whitespacesAndNewlines), of: repository)
        }
        guard
            let base = try await ReviewBase.resolve(
                detection: detection, override: override, in: worktree, git: git)
        else {
            throw Failure("the base picked in Seam, \(override ?? ""), no longer resolves")
        }
        return base.commit
    }
}

struct Resolve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resolve a thread.")

    @OptionGroup var options: ThreadOptions
    @OptionGroup(visibility: .hidden) var signature: Signature
    @Argument(help: idHelp) var id: String

    func run() async throws { try await setResolved(true, id, options) }
}

struct Reopen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Reopen a resolved thread.")

    @OptionGroup var options: ThreadOptions
    @OptionGroup(visibility: .hidden) var signature: Signature
    @Argument(help: idHelp) var id: String

    func run() async throws { try await setResolved(false, id, options) }
}

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete a thread with all its comments.")

    @OptionGroup var options: ThreadOptions
    @OptionGroup(visibility: .hidden) var signature: Signature
    @Argument(help: idHelp) var id: String

    func run() async throws {
        let (repository, _) = try await options.worktree()
        let id = String(id.trimmingPrefix("#"))
        try threadStore().update(repository) { threads throws(ThreadError) in
            try ThreadRules.delete(&threads, id: id)
        }
        print("Deleted #\(id).")
    }
}

private func setResolved(_ resolved: Bool, _ id: String, _ options: ThreadOptions) async throws {
    let (repository, _) = try await options.worktree()
    let id = String(id.trimmingPrefix("#"))
    try threadStore().update(repository) { threads throws(ThreadError) in
        try ThreadRules.setResolved(resolved, &threads, id: id, now: .now)
    }
    print(resolved ? "Resolved #\(id)." : "Reopened #\(id).")
}

/// A failure while running, not in the arguments: printed as "Error: …" with status 1, without
/// the usage text a `ValidationError` brings.
struct Failure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
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
        case .emptyComment: "the comment is empty"
        case .unsupportedVersion(let version):
            "the thread store was written by a newer Seam (format \(version))"
        case .unreadable(let message): "can't read the thread store: \(message)"
        case .unwritable(let message): "can't write the thread store: \(message)"
        }
    }
}
