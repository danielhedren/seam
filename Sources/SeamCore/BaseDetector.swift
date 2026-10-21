import Foundation
import GitKit
import os

public struct DetectionSettings: Equatable, Sendable {
    /// A ref name, full (`refs/remotes/origin/main`) or short (`origin/main`, `main`); nil
    /// resolves `origin/HEAD`, then `origin/main`, `main`, `origin/master`, `master`.
    public var defaultBase: String?
    /// Globs over short ref names (`origin/renovate/x`) never considered as parents.
    public var ignoredRefs: [Glob]

    public init(
        defaultBase: String? = nil,
        ignoredRefs: [Glob] = [Glob("origin/dependabot/**"), Glob("origin/renovate/**")]
    ) {
        self.defaultBase = defaultBase
        self.ignoredRefs = ignoredRefs
    }
}

public struct ParentCandidate: Equatable, Sendable {
    /// Full ref name.
    public var ref: String
    public var tip: String
    /// Commits in HEAD that this ref does not contain.
    public var commitCount: Int
    public var tipIsBoundary = false
    public var isUpstream = false
    public var isDefaultBase = false
    public var committerDate = 0

    public var name: String { RefName.short(ref) }
    public var isRemote: Bool { ref.hasPrefix(RefName.remotes) }

    public init(ref: String, tip: String, commitCount: Int) {
        self.ref = ref
        self.tip = tip
        self.commitCount = commitCount
    }

    /// SPEC §5.1 step 4: fewest commits, then the tie-breaks in order.
    static func ranked(_ candidates: [ParentCandidate]) -> [ParentCandidate] {
        candidates.sorted { a, b in
            if a.commitCount != b.commitCount { return a.commitCount < b.commitCount }
            if a.tipIsBoundary != b.tipIsBoundary { return a.tipIsBoundary }
            if a.isUpstream != b.isUpstream { return a.isUpstream }
            if a.isDefaultBase != b.isDefaultBase { return a.isDefaultBase }
            if a.isRemote != b.isRemote { return a.isRemote }
            if a.committerDate != b.committerDate { return a.committerDate > b.committerDate }
            return a.ref < b.ref
        }
    }
}

public struct BaseDetection: Equatable, Sendable {
    public var head: String
    /// Short branch name; nil when detached.
    public var branch: String?
    /// Nil when no other ref shares history with HEAD.
    public var parent: ParentCandidate?
    public var base: String
    /// Ranked, the chosen parent first; the default base is always included for the picker.
    public var candidates: [ParentCandidate]

    public var uniqueCommitCount: Int { parent?.commitCount ?? 0 }
}

public enum Revision: Sendable {
    case head
    /// A commit reviewed as if it were checked out on `branch`.
    case commit(String, branch: String?)
}

public struct BaseDetector: Sendable {
    /// `git hash-object -t tree /dev/null`: the base when HEAD shares no history with any ref.
    public static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    private let git: any GitClient
    private let settings: DetectionSettings
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "SeamCore")

    public init(git: any GitClient, settings: DetectionSettings = DetectionSettings()) {
        self.git = git
        self.settings = settings
    }

    public func detect(in worktree: URL, at revision: Revision = .head) async throws(GitError)
        -> BaseDetection
    {
        let interval = signposter.beginInterval("detect")
        defer { signposter.endInterval("detect", interval) }

        let context = try await loadContext(worktree, revision)
        let candidates = try await findCandidates(context)
        var ranked = ParentCandidate.ranked(candidates)
        guard let parent = ranked.first else {
            return BaseDetection(
                head: context.head, branch: context.branchName, parent: nil,
                base: Self.emptyTree, candidates: [])
        }
        let base =
            parent.commitCount == 0
            ? context.head
            : try await line(["merge-base", parent.ref, context.head], context.directory)
        if let defaultRef = context.defaultBase, !ranked.contains(where: { $0.ref == defaultRef }),
            let row = context.refs[defaultRef]
        {
            ranked.append(try await candidate(row, context, count: nil))
        }
        return BaseDetection(
            head: context.head, branch: context.branchName, parent: parent, base: base,
            candidates: ranked)
    }

    /// The base for a user-chosen parent (SPEC §5.3); nil when `ref` no longer resolves or
    /// shares no history with HEAD.
    public func base(forParent ref: String, in worktree: URL) async throws(GitError) -> String? {
        try await git.optionalLine(["merge-base", "--end-of-options", ref, "HEAD"], in: worktree)
    }

    /// Commits on HEAD since `base`, for a parent that wasn't among the candidates.
    public func commitCount(since base: String, in worktree: URL) async throws(GitError) -> Int? {
        try await git.optionalLine(["rev-list", "--count", "\(base)..HEAD"], in: worktree)
            .flatMap(Int.init)
    }

    /// A typed ref as the full name the candidates use (`main` → `refs/heads/main`), or the
    /// commit id when it names no ref; nil when it doesn't resolve to a commit.
    public func resolveRef(_ name: String, in worktree: URL) async throws(GitError) -> String? {
        guard
            let commit = try await git.optionalLine(
                ["rev-parse", "--verify", "--quiet", "--end-of-options", name + "^{commit}"],
                in: worktree)
        else { return nil }
        let full = try await git.optionalLine(
            ["rev-parse", "--verify", "--quiet", "--symbolic-full-name", "--end-of-options", name],
            in: worktree)
        return full.flatMap { $0.isEmpty ? nil : $0 } ?? commit
    }

    // MARK: - Steps

    private struct RefRow {
        var ref: String
        var tip: String
        var upstream: String
        var committerDate: Int
    }

    private struct Context {
        var directory: URL
        var head: String
        /// Full ref name of the reviewed branch.
        var branch: String?
        var refs: [String: RefRow]
        /// Refs that may be parents (SPEC §5.1 step 1, before descendant filtering).
        var eligible: Set<String>
        var upstream: String?
        var defaultBase: String?

        var branchName: String? { branch.map(RefName.shortBranch) }
    }

    private func loadContext(_ directory: URL, _ revision: Revision) async throws(GitError)
        -> Context
    {
        let head: String
        let branch: String?
        switch revision {
        case .head:
            head = try await line(["rev-parse", "--verify", "HEAD^{commit}"], directory)
            branch = try await git.optionalLine(["symbolic-ref", "-q", "HEAD"], in: directory)
        case .commit(let commit, let name):
            head = try await line(["rev-parse", "--verify", "\(commit)^{commit}"], directory)
            branch = name.map { RefName.heads + $0 }
        }

        let format = "%(refname)%00%(objectname)%00%(upstream)%00%(committerdate:unix)%00%(symref)"
        let output = try await git.string(
            ["for-each-ref", "--format=\(format)", "refs/heads", "refs/remotes"], in: directory)
        var refs: [String: RefRow] = [:]
        var symbolic: [String: String] = [:]
        for row in output.split(separator: "\n") {
            let fields = row.split(separator: "\0", omittingEmptySubsequences: false).map(
                String.init)
            guard fields.count == 5 else { continue }
            if !fields[4].isEmpty {
                symbolic[fields[0]] = fields[4]
                continue
            }
            refs[fields[0]] = RefRow(
                ref: fields[0], tip: fields[1], upstream: fields[2],
                committerDate: Int(fields[3]) ?? 0)
        }

        let remotes = try await git.string(["remote"], in: directory).split(separator: "\n")
        let upstream = branch.flatMap { refs[$0]?.upstream }.flatMap { $0.isEmpty ? nil : $0 }
        let defaultBase = resolveDefaultBase(refs, symbolic)
        var excluded: Set<String> = []
        if let branch {
            excluded.insert(branch)
            let name = RefName.shortBranch(branch)
            for remote in remotes { excluded.insert("\(RefName.remotes)\(remote)/\(name)") }
            if let upstream, upstream.hasSuffix("/\(name)") { excluded.insert(upstream) }
        }
        // The default branch itself (local `main`) is reviewed against its own remote copy.
        if let defaultBase { excluded.remove(defaultBase) }
        let eligible = Set(refs.keys).subtracting(excluded).filter { ref in
            let name = RefName.short(ref)
            return !settings.ignoredRefs.contains { $0.matches(name) }
        }

        return Context(
            directory: directory, head: head, branch: branch, refs: refs, eligible: eligible,
            upstream: upstream, defaultBase: defaultBase)
    }

    private func resolveDefaultBase(_ refs: [String: RefRow], _ symbolic: [String: String])
        -> String?
    {
        let configured =
            settings.defaultBase.map { name in
                [name, RefName.remotes + name, RefName.heads + name]
            } ?? []
        let preferred =
            configured + [
                symbolic["refs/remotes/origin/HEAD"], "refs/remotes/origin/main",
                "refs/heads/main", "refs/remotes/origin/master", "refs/heads/master",
            ]
        return preferred.compactMap { $0 }.first { refs[$0] != nil }
    }

    private func findCandidates(_ context: Context) async throws(GitError) -> [ParentCandidate] {
        let containing = try await refsContaining([context.head], context)
            .intersection(context.eligible)
        let parentsContaining = try await parentsAmong(containing, context)
        if !parentsContaining.isEmpty {
            var result: [ParentCandidate] = []
            for ref in parentsContaining {
                if let row = context.refs[ref] {
                    result.append(try await candidate(row, context, count: 0))
                }
            }
            return result
        }

        // Every remaining ref that contains HEAD is a branch stacked on it, not a parent.
        let remaining = context.eligible.subtracting(containing)
        guard !remaining.isEmpty else { return [] }
        let input =
            ([context.head] + remaining.sorted().map { "^" + $0 }).joined(separator: "\n") + "\n"
        let walk = String(
            decoding: try await git.run(
                ["rev-list", "--boundary", "--stdin"], in: context.directory,
                input: Data(input.utf8)),
            as: UTF8.self)
        var unique = 0
        var boundaries: [String] = []
        for row in walk.split(separator: "\n") {
            if row.hasPrefix("-") {
                boundaries.append(String(row.dropFirst()))
            } else {
                unique += 1
            }
        }
        guard !boundaries.isEmpty else { return [] }

        // A ref containing every boundary lacks exactly the unique commits, the minimum possible.
        var perBoundary: [Set<String>] = []
        for boundary in boundaries {
            perBoundary.append(
                try await refsContaining([boundary], context).intersection(remaining))
        }
        let containsAll = perBoundary.dropFirst().reduce(perBoundary[0]) { $0.intersection($1) }
        let boundarySet = Set(boundaries)
        if !containsAll.isEmpty {
            var result: [ParentCandidate] = []
            for ref in containsAll {
                guard let row = context.refs[ref] else { continue }
                var item = try await candidate(row, context, count: unique)
                item.tipIsBoundary = boundarySet.contains(row.tip)
                result.append(item)
            }
            return result
        }

        // No single ref covers every boundary (e.g. a stacked branch that merged a newer main):
        // count each candidate, once per distinct tip.
        let union = perBoundary.reduce(into: Set<String>()) { $0.formUnion($1) }
        var counts: [String: Int] = [:]
        var result: [ParentCandidate] = []
        for ref in union.sorted() {
            guard let row = context.refs[ref] else { continue }
            let count: Int
            if let known = counts[row.tip] {
                count = known
            } else {
                count = try await commitsNotIn(row.tip, context)
                counts[row.tip] = count
            }
            var item = try await candidate(row, context, count: count)
            item.tipIsBoundary = boundarySet.contains(row.tip)
            result.append(item)
        }
        return result
    }

    /// A ref containing HEAD is either a branch HEAD was cut from (possibly moved on since) or a
    /// branch cut from HEAD. The graph cannot tell them apart; the default base, the upstream and
    /// branch creation order in the reflog can.
    private func parentsAmong(_ containing: Set<String>, _ context: Context) async throws(GitError)
        -> [String]
    {
        let known = containing.filter { $0 == context.defaultBase || $0 == context.upstream }
        if !known.isEmpty { return known.sorted() }
        var parents: [String] = []
        for ref in containing.sorted() where try await isOlderBranch(ref, context) {
            parents.append(ref)
        }
        return parents
    }

    /// Without reflog evidence, a ref at HEAD's own commit counts as the parent (a fresh worktree)
    /// and a ref ahead of HEAD counts as a descendant.
    private func isOlderBranch(_ ref: String, _ context: Context) async throws(GitError) -> Bool {
        let fallback = context.refs[ref]?.tip == context.head
        guard let branch = context.branch, let ownCreated = try await created(branch, context)
        else {
            return fallback
        }
        var local = ref
        if ref.hasPrefix(RefName.remotes) {
            let short = RefName.short(ref)
            guard let slash = short.firstIndex(of: "/") else { return fallback }
            local = RefName.heads + short[short.index(after: slash)...]
        }
        guard let otherCreated = try await created(local, context) else { return fallback }
        return otherCreated <= ownCreated
    }

    private func created(_ ref: String, _ context: Context) async throws(GitError) -> Int? {
        guard context.refs[ref] != nil else { return nil }
        let log = try await git.optionalLine(
            ["reflog", "show", "--format=%ct", ref, "--"], in: context.directory)
        return log?.split(separator: "\n").last.flatMap { Int($0) }
    }

    private func candidate(_ row: RefRow, _ context: Context, count: Int?) async throws(GitError)
        -> ParentCandidate
    {
        let commitCount: Int
        if let count {
            commitCount = count
        } else {
            commitCount = try await commitsNotIn(row.tip, context)
        }
        var item = ParentCandidate(ref: row.ref, tip: row.tip, commitCount: commitCount)
        item.isUpstream = row.ref == context.upstream
        item.isDefaultBase = row.ref == context.defaultBase
        item.committerDate = row.committerDate
        return item
    }

    private func commitsNotIn(_ tip: String, _ context: Context) async throws(GitError) -> Int {
        Int(try await line(["rev-list", "--count", context.head, "^" + tip], context.directory))
            ?? 0
    }

    private func refsContaining(_ commits: [String], _ context: Context) async throws(GitError)
        -> Set<String>
    {
        let arguments =
            ["for-each-ref", "--format=%(refname)"] + commits.map { "--contains=\($0)" }
            + ["refs/heads", "refs/remotes"]
        let output = try await git.string(arguments, in: context.directory)
        return Set(output.split(separator: "\n").map(String.init)).intersection(context.refs.keys)
    }

    private func line(_ arguments: [String], _ directory: URL) async throws(GitError) -> String {
        let output = try await git.string(arguments, in: directory)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
