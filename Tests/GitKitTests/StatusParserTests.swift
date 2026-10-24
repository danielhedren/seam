import Foundation
import Testing

@testable import GitKit

@Suite(.timeLimit(.minutes(1))) struct StatusParserTests {
    private func fixture(_ name: String) throws -> Status {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "v2z", subdirectory: "Fixtures"))
        return try StatusParser.parse(try Data(contentsOf: url))
    }

    @Test func readsBranchHeadersAndEveryEntry() throws {
        let status = try fixture("status")
        #expect(status.branch == "main")
        #expect(status.head?.count == 40)
        #expect(status.entries.count == 18)
    }

    @Test func stagedAndUnstagedLettersAreSeparate() throws {
        let entries = try fixture("status").entries
        let modified = try #require(entries.first { $0.path == "modified.txt" })
        #expect(modified.kind == .ordinary)
        #expect(modified.index == "M")
        #expect(modified.worktree == "M")
        let added = try #require(entries.first { $0.path == "added.txt" })
        #expect(added.index == "A")
        #expect(added.worktree == ".")
    }

    @Test func renameCarriesItsSourcePath() throws {
        let entries = try fixture("status").entries
        let renamed = try #require(entries.first { $0.path == "new-name.txt" })
        #expect(renamed.kind == .renamedOrCopied)
        #expect(renamed.originalPath == "old-name.txt")
        #expect(entries.contains { $0.path == "pure-new.txt" && $0.originalPath == "pure-old.txt" })
    }

    @Test func untrackedAndIgnoredPathsKeepSpaces() throws {
        let entries = try fixture("status").entries
        #expect(entries.contains { $0.kind == .untracked && $0.path == "untracked file.txt" })
        #expect(entries.contains { $0.kind == .ignored && $0.path == "ignored.log" })
        #expect(entries.contains { $0.path == "åäö.txt" && $0.kind == .ordinary })
    }

    @Test func unmergedEntryIsRecognised() throws {
        let entry = try #require(try fixture("status-unmerged").entries.first)
        #expect(entry.kind == .unmerged)
        #expect(entry.path == "both.txt")
        #expect(entry.index == "U")
    }

    @Test func detachedAndInitialHeadsAreNil() throws {
        let data = Data("# branch.oid (initial)\0# branch.head (detached)\0".utf8)
        let status = try StatusParser.parse(data)
        #expect(status.head == nil)
        #expect(status.branch == nil)
    }

    @Test func truncatedEntryIsAnError() {
        #expect(throws: GitError.self) { try StatusParser.parse(Data("1 M. N...\0".utf8)) }
    }
}
