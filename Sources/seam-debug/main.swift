import Foundation
import GitKit
import SeamCore

// Debug tool for M1 (SPEC §14): prints what Seam would show for a worktree.
//
//   seam-debug [path] [--scope all|committed|uncommitted] [--commit <rev> [--branch <name>]]
//   seam-debug [path] --worktrees

struct Arguments {
    var path = FileManager.default.currentDirectoryPath
    var scope = ReviewScope.all
    var commit: String?
    var branch: String?
    var listWorktrees = false

    init(_ raw: [String]) throws {
        var raw = raw[...]
        while let argument = raw.popFirst() {
            switch argument {
            case "--scope":
                guard let value = raw.popFirst(), let scope = ReviewScope(rawValue: value) else {
                    throw Usage()
                }
                self.scope = scope
            case "--commit": commit = try Self.value(&raw)
            case "--branch": branch = try Self.value(&raw)
            case "--worktrees": listWorktrees = true
            case let flag where flag.hasPrefix("-"): throw Usage()
            default: path = argument
            }
        }
    }

    private static func value(_ raw: inout ArraySlice<String>) throws -> String {
        guard let value = raw.popFirst() else { throw Usage() }
        return value
    }
}

struct Usage: Error {}

func milliseconds(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    return "\(seconds * 1000 + attoseconds / 1_000_000_000_000_000) ms"
}

let git = CLIGitClient()
let arguments: Arguments
do {
    arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
} catch {
    print(
        "usage: seam-debug [path] [--scope all|committed|uncommitted] [--commit rev [--branch name]] [--worktrees]"
    )
    exit(64)
}

do {
    let directory = URL(fileURLWithPath: arguments.path, isDirectory: true)
    let service = RepositoryService(git: git)
    let (repository, worktree) = try await service.open(directory)
    print("repo      \(repository.commonDirectory.path)")

    let detector = BaseDetector(git: git)
    if arguments.listWorktrees {
        for item in try await service.worktrees(of: repository) {
            guard !item.isMissing else {
                print("  \(item.name)  (missing)")
                continue
            }
            let clock = ContinuousClock()
            var detection: BaseDetection?
            let elapsed = try await clock.measure {
                detection = try await detector.detect(in: item.path)
            }
            let parent = detection?.parent.map { "\($0.name) +\($0.commitCount)" } ?? "none"
            print(
                "  \(item.name)  [\(item.branch ?? "detached")]  vs \(parent)  \(milliseconds(elapsed))"
            )
        }
        exit(0)
    }

    let revision: Revision = arguments.commit.map { .commit($0, branch: arguments.branch) } ?? .head
    let clock = ContinuousClock()
    var detected: BaseDetection?
    let elapsed = try await clock.measure {
        detected = try await detector.detect(in: worktree, at: revision)
    }
    guard let detection = detected else { exit(1) }
    print("worktree  \(worktree.path)")
    print("branch    \(detection.branch ?? "(detached)")  head \(detection.head.prefix(9))")
    if let parent = detection.parent {
        print("parent    \(parent.name)  · \(parent.commitCount) commits")
    } else {
        print("parent    none")
    }
    print("base      \(detection.base.prefix(9))  (\(milliseconds(elapsed)))")
    for candidate in detection.candidates.dropFirst() {
        print("  also    \(candidate.name)  · \(candidate.commitCount) commits")
    }

    let head = arguments.commit ?? "HEAD"
    let review = try await ReviewDiffBuilder(git: git).build(
        worktree: worktree, base: detection.base, head: head, scope: arguments.scope)
    print(
        "\n\(review.files.count) files  +\(review.additions) −\(review.deletions)  (\(arguments.scope.rawValue))"
    )
    for file in review.files {
        let diff = file.diff
        var name = diff.path
        if case .renamed = diff.status, let old = diff.oldPath { name = "\(old) → \(name)" }
        let note = file.isUntracked ? "  untracked" : diff.isBinary ? "  binary" : ""
        print("  \(diff.status.letter) \(name)  +\(diff.additions) −\(diff.deletions)\(note)")
    }
} catch {
    print("error: \(error)")
    exit(1)
}
