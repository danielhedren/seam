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

            Reading the output: line numbers are from when a comment was written; a line under \
            the header says where they are now, that they're gone (outdated), or that they're \
            on the old side, lines your change removed. Ids starting gh- are a GitHub pull \
            request's threads: seam can't change them, and each shows the gh command that \
            answers it. Times are ISO 8601; pass wait's "As of" to the next --since. Exit \
            status 64 means the arguments were wrong, 1 that the command failed, 2 that wait \
            timed out.
            """,
        subcommands: [Open.self],
        groupedSubcommands: [
            CommandGroup(
                name: "Review threads",
                subcommands: [
                    Threads.self, ShowThread.self, Conversation.self, Wait.self, Comment.self,
                    Reply.self,
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
        #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments =
                Self.app.map { ["-a", $0.path, url.absoluteString] }
                ?? ["-b", "com.danielhedren.seam", url.absoluteString]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { throw ExitCode(process.terminationStatus) }
        #else
            throw Failure("Seam has no app on this platform; open \(url.absoluteString) on a Mac")
        #endif
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
            // Only git's own answer means "not a worktree"; anything else keeps its cause.
            if case .nonZeroExit(_, _, let stderr) = error, stderr.contains("not a git repository")
            {
                throw Failure("\(folder.path) is not in a git worktree")
            }
            throw Failure("can't read the worktree at \(folder.path): \(error)")
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
    @Flag(help: "Include notes, which ask for no answer.") var notes = false
    @Flag(help: repoHelp) var repo = false
    @Option(help: sinceHelp, transform: parseTime) var since: Date?
    @Flag(help: jsonHelp) var json = false

    func run() async throws {
        let (repository, worktree) = try await options.worktree()
        let scope = ThreadScope(
            worktree: repo ? nil : worktree.path, includesResolved: all, includesNotes: notes,
            since: since)
        let (found, read) = try allThreads(repository)
        let threads = found.filter(scope.contains)
        if json {
            try printJSON(
                threads.map {
                    ThreadOutput($0, readAt: read[$0.worktree], placement: placement(of: $0))
                })
            return
        }
        var parts = threads.map {
            ThreadText.format(
                $0, showsWorktree: repo, read: read[$0.worktree], placement: placement(of: $0))
        }
        if threads.isEmpty {
            parts.append(
                since.map { "No threads changed since \(ThreadTime.string($0))." }
                    ?? (all ? "No threads." : "No open threads."))
        }
        parts += try conversations(repository, worktree: repo ? nil : worktree.path, since: since)
        print(parts.joined(separator: "\n\n"))
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
        var changed: [ThreadOutput]
        var deleted: [String]
    }

    func run() async throws {
        let (repository, worktree) = try await options.worktree()
        let store = threadStore()
        try FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true)
        // Watching starts before the first read, so a write in between still wakes the wait.
        let events = SystemFileWatcher().events(for: [store.directory])
        guard
            let (changes, asOf) = try await ThreadWait.next(
                in: ThreadScope(
                    worktree: repo ? nil : worktree.path, includesNotes: true, since: since),
                read: { () throws(ThreadError) in
                    try store.threads(for: repository)
                        + store.gitHubThreads(for: repository).threads
                },
                events: events, clock: ContinuousClock(), timeout: timeout.map { .seconds($0) })
        else {
            let seconds = timeout ?? 0
            FileHandle.standardError.write(
                Data("No thread changed within \(seconds) second\(seconds == 1 ? "" : "s").\n".utf8)
            )
            throw ExitCode(2)
        }
        let read = (try? store.gitHubThreads(for: repository).read) ?? [:]
        if json {
            try printJSON(
                Output(
                    asOf: asOf,
                    changed: changes.changed.map {
                        ThreadOutput($0, readAt: read[$0.worktree], placement: placement(of: $0))
                    }, deleted: changes.deleted))
            return
        }
        var parts = changes.changed.map {
            ThreadText.format(
                $0, showsWorktree: repo, read: read[$0.worktree], placement: placement(of: $0))
        }
        parts += changes.deleted.map { id in
            id.hasPrefix(ReviewThread.gitHubPrefix)
                ? "#\(id) is gone from the pull request" : "#\(id) deleted"
        }
        parts.append("As of \(ThreadTime.string(asOf))")
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
    guard let date = ThreadTime.date(text) else {
        throw ValidationError("expected an ISO 8601 time such as 2026-10-22T18:30:00Z")
    }
    return date
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
        let (threads, read) = try allThreads(repository)
        guard let thread = threads.first(where: { $0.id == id }) else {
            throw ThreadError.unknownThread(String(id))
        }
        if json {
            try printJSON(
                ThreadOutput(
                    thread, readAt: read[thread.worktree], placement: placement(of: thread)))
        } else {
            print(
                ThreadText.format(
                    thread, read: read[thread.worktree], placement: placement(of: thread)))
        }
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
        try refuseGitHub(id, in: repository)
        try threadStore().update(repository) { threads throws(ThreadError) in
            try ThreadRules.reply(&threads, to: id, author: author, body: text, now: .now)
        }
        print("Replied to #\(id).")
    }
}

struct Comment: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open a thread on lines of a file, as a reviewer, or leave a note.",
        discussion: """
            With --note it's a note for whoever reviews: something to know about these lines, \
            asking no answer. Notes aren't listed as open threads.
            """)

    @OptionGroup var options: ThreadOptions
    @OptionGroup var signature: Signature
    @Argument(
        help: ArgumentHelp(
            "The file and lines, relative to the worktree or the current folder.",
            valueName: "file:line[-end]"))
    var location: String
    @Flag(help: "The lines are on the old side: the base the diff starts from.") var old = false
    @Flag(help: "A note for the reviewer, asking no answer.") var note = false
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
        let origin = await ThreadOrigin.find(path: relative, in: worktree, git: CLIGitClient())
        let thread = try threadStore().update(repository) { threads throws(ThreadError) in
            try ThreadRules.open(
                &threads, worktree: worktree.path, anchor: anchor, author: author, body: text,
                now: .now, origin: origin, isNote: note)
        }
        print(note ? "Left note #\(thread.id)." : "Opened #\(thread.id).")
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
            throw Failure(
                override.map { "the base picked in Seam, \($0), no longer resolves" }
                    ?? "the base Seam detected for this worktree no longer resolves")
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
        try refuseGitHub(id, in: repository)
        try threadStore().update(repository) { threads throws(ThreadError) in
            try ThreadRules.delete(&threads, id: id)
        }
        print("Deleted #\(id).")
    }
}

private func setResolved(_ resolved: Bool, _ id: String, _ options: ThreadOptions) async throws {
    let (repository, _) = try await options.worktree()
    let id = String(id.trimmingPrefix("#"))
    try refuseGitHub(id, in: repository)
    try threadStore().update(repository) { threads throws(ThreadError) in
        try ThreadRules.setResolved(resolved, &threads, id: id, now: .now)
    }
    print(resolved ? "Resolved #\(id)." : "Reopened #\(id).")
}

/// Where a thread's new-side lines are in its worktree's files now, by the app's own rules
/// (SPEC §7.7); nil for the old side, which `ThreadText` explains instead.
private func placement(of thread: ReviewThread) -> ThreadPlacement? {
    guard thread.anchor.side == .new else { return nil }
    let path = thread.anchor.path
    let file = URL(fileURLWithPath: thread.worktree).appending(path: path)
    guard let data = FileManager.default.contents(atPath: file.path) else { return .notShown }
    let lines = TextLines.split(String(decoding: data, as: UTF8.self))
    let context = ThreadPlacer.Context(paths: [path], text: { _, _ in lines })
    return ThreadPlacer.place([thread], in: context).first?.placement
}

/// Seam's threads and the pull request threads the app read last, with when each worktree's
/// were read (SPEC §7.9).
private func allThreads(_ repository: Repository) throws(ThreadError)
    -> (threads: [ReviewThread], read: [String: Date])
{
    let store = threadStore()
    let github = try store.gitHubThreads(for: repository)
    return (try store.threads(for: repository) + github.threads, github.read)
}

/// The pull request conversations the app read last, as text: one worktree's, or with `nil`
/// every worktree's, each naming its worktree.
private func conversations(_ repository: Repository, worktree: String?, since: Date?)
    throws(ThreadError) -> [String]
{
    let github = try threadStore().gitHubThreads(for: repository)
    return github.conversations.sorted { $0.key < $1.key }
        .filter { worktree == nil || $0.key == worktree }
        .compactMap { key, conversation in
            ThreadText.format(
                conversation, showsWorktree: worktree == nil ? key : nil, since: since,
                read: github.read[key])
        }
}

struct Conversation: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show this worktree's pull request conversation.",
        discussion: """
            The comments on the pull request that aren't on lines, and its reviews' verdicts, \
            oldest first, as the app last read them from GitHub. `seam threads` prints it too.
            """)

    @OptionGroup var options: ThreadOptions
    @OptionGroup(visibility: .hidden) var signature: Signature
    @Option(help: sinceHelp, transform: parseTime) var since: Date?
    @Flag(help: jsonHelp) var json = false

    private struct Output: Encodable {
        var conversation: PullRequestConversation
        var replyCommand: String
        var readAt: Date?
    }

    func run() async throws {
        let (repository, worktree) = try await options.worktree()
        let github = try threadStore().gitHubThreads(for: repository)
        guard var conversation = github.conversations[worktree.path] else {
            print("No pull request conversation has been read for this worktree.")
            return
        }
        conversation.items = conversation.items.filter { item in
            since.map { item.created >= $0 } ?? true
        }
        if json {
            try printJSON(
                Output(
                    conversation: conversation, replyCommand: conversation.gitHubReply,
                    readAt: github.read[worktree.path]))
        } else {
            print(
                ThreadText.format(conversation, read: github.read[worktree.path])
                    ?? "Nothing in the conversation\(since == nil ? "" : " since then").")
        }
    }
}

/// GitHub's threads are read-only here: the error says how to answer one with gh instead.
private func refuseGitHub(_ id: String, in repository: Repository) throws {
    guard id.hasPrefix(ReviewThread.gitHubPrefix),
        let thread = try threadStore().gitHubThreads(for: repository).threads.first(where: {
            $0.id == id
        }),
        !thread.capabilities.contains(.reply), let github = thread.github,
        let reply = thread.gitHubReply
    else { return }
    throw Failure(
        "#\(id) is a thread on GitHub pull request #\(github.pullRequest), which seam can't "
            + "change. Answer it on GitHub: write your reply to reply.md, then run\n  \(reply)")
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
    encoder.dateEncodingStrategy = ThreadTime.encoding
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
