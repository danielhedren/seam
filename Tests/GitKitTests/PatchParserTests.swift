import Foundation
import Testing

@testable import GitKit

@Suite(.timeLimit(.minutes(1))) struct PatchParserTests {
    let files: [String: FileDiff]

    init() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "worktree-changes", withExtension: "patch", subdirectory: "Fixtures"))
        let parsed = try PatchParser.parse(try Data(contentsOf: url))
        files = Dictionary(uniqueKeysWithValues: parsed.map { ($0.path, $0) })
    }

    @Test func parsesEveryFileInTheRecordedPatch() {
        #expect(files.count == 15)
    }

    @Test func modifiedFileHasHunksWithLineNumbers() throws {
        let file = try #require(files["modified.txt"])
        #expect(file.status == .modified)
        #expect(file.additions == 3)
        #expect(file.deletions == 2)
        let first = try #require(file.hunks.first)
        #expect(first.oldStart == 1)
        let changed = try #require(first.lines.first { $0.kind == .added })
        #expect(changed.text == "TWO")
        #expect(changed.newNumber == 2)
        #expect(changed.oldNumber == nil)
    }

    @Test func addedAndDeletedFilesHaveOnlyOnePath() throws {
        let added = try #require(files["added.txt"])
        #expect(added.status == .added)
        #expect(added.oldPath == nil)
        #expect(added.newMode == "100644")
        let deleted = try #require(files["deleted.txt"])
        #expect(deleted.status == .deleted)
        #expect(deleted.newPath == nil)
    }

    @Test func emptyAddedFileHasNoHunks() throws {
        let file = try #require(files["empty-added.txt"])
        #expect(file.status == .added)
        #expect(file.hunks.isEmpty)
    }

    @Test func renameWithEditKeepsBothPathsAndSimilarity() throws {
        let file = try #require(files["new-name.txt"])
        #expect(file.oldPath == "old-name.txt")
        #expect(file.status == .renamed(similarity: 86))
        #expect(file.additions == 1)
    }

    @Test func pureRenameHasNoHunks() throws {
        let file = try #require(files["pure-new.txt"])
        #expect(file.oldPath == "pure-old.txt")
        #expect(file.status == .renamed(similarity: 100))
        #expect(file.hunks.isEmpty)
    }

    @Test func copyIsDetected() throws {
        let file = try #require(files["copy-of-modified.txt"])
        #expect(file.oldPath == "modified.txt")
        #expect(file.status == .copied(similarity: 100))
    }

    @Test func binaryFileIsFlagged() throws {
        let file = try #require(files["binary.bin"])
        #expect(file.isBinary)
        #expect(file.hunks.isEmpty)
    }

    @Test func modeOnlyChangeKeepsBothModes() throws {
        let file = try #require(files["mode.sh"])
        #expect(file.oldMode == "100644")
        #expect(file.newMode == "100755")
        #expect(file.hunks.isEmpty)
    }

    @Test func noNewlineMarkerAttachesToThePrecedingLine() throws {
        let lines = try #require(files["no-newline.txt"]?.hunks.first?.lines)
        #expect(lines.map(\.noNewlineAtEnd) == [true, true])
        #expect(lines.map(\.kind) == [.removed, .added])
    }

    @Test func symlinkIsAnAdditionOfItsTarget() throws {
        let file = try #require(files["link"])
        #expect(file.newMode == "120000")
        #expect(file.hunks.first?.lines.first?.text == "modified.txt")
    }

    @Test func pathsWithSpacesUnicodeAndQuotesAreDecoded() {
        #expect(files["with space.txt"] != nil)
        #expect(files["åäö.txt"] != nil)
        #expect(files["quote\"d.txt"] != nil)
    }

    @Test func carriageReturnsStayInLineText() throws {
        let lines = try #require(files["crlf.txt"]?.hunks.first?.lines)
        #expect(lines.contains { $0.text == "B\r" && $0.kind == .added })
    }

    @Test(arguments: [
        ("@@ -1,3 +1,4 @@ func main()", 1, 3, 1, 4, "func main()"),
        ("@@ -5 +5 @@", 5, 1, 5, 1, ""),
        ("@@ -0,0 +1,2 @@", 0, 0, 1, 2, ""),
    ])
    func hunkHeaders(
        line: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String
    )
        throws
    {
        let hunk = try #require(PatchParser.parseHunkHeader(line))
        let actual: [Int] = [hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount]
        #expect(actual == [oldStart, oldCount, newStart, newCount])
        #expect(hunk.section == section)
    }

    @Test func truncatedHunkIsAnError() {
        let patch = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-a\n"
        #expect(throws: GitError.self) { try PatchParser.parse(Data(patch.utf8)) }
    }
}

@Suite(.timeLimit(.minutes(1))) struct CQuoteTests {
    @Test(arguments: [
        (#""plain""#, "plain"),
        (#""quote\"d""#, "quote\"d"),
        (#""tab\there""#, "tab\there"),
        (#""back\\slash""#, "back\\slash"),
        (#""\303\245""#, "å"),
        ("unquoted", "unquoted"),
    ])
    func unquotes(input: String, expected: String) {
        #expect(CQuote.unquote(Array(input.utf8)[...]) == expected)
    }

    @Test func rejectsUnterminatedQuote() {
        #expect(CQuote.unquote(Array(#""open"#.utf8)[...]) == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) struct WorktreeListParserTests {
    @Test func parsesMainLockedPrunableAndDetachedEntries() {
        let fields = [
            "worktree /repo", "HEAD aaa", "branch refs/heads/main", "",
            "worktree /wt/locked", "HEAD bbb", "branch refs/heads/feature", "locked agent busy", "",
            "worktree /wt/gone", "HEAD ccc", "detached",
            "prunable gitdir file points to non-existent location",
            "",
        ]
        let data = Data(fields.joined(separator: "\0").utf8) + Data([0])
        let entries = WorktreeListParser.parse(data)
        #expect(entries.map(\.path) == ["/repo", "/wt/locked", "/wt/gone"])
        #expect(entries[0].branch == "refs/heads/main")
        #expect(entries[1].lockReason == "agent busy")
        #expect(entries[2].isDetached)
        #expect(entries[2].branch == nil)
        #expect(entries[2].prunableReason?.hasPrefix("gitdir") == true)
    }

    @Test func lockedWithoutReasonIsStillLocked() {
        let data = Data("worktree /wt\0HEAD aaa\0branch refs/heads/x\0locked\0\0".utf8)
        #expect(WorktreeListParser.parse(data).first?.lockReason == "")
    }
}
