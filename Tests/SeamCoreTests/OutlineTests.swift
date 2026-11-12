import Foundation
import GitKit
import Testing

@testable import SeamCore

/// The definitions a file's change touches (SPEC §7.4).
@Suite(.timeLimit(.minutes(1))) struct OutlineTests {
    private func diff(removed: [Int], added: [Int]) -> FileDiff {
        var hunk = Hunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 0, section: "")
        hunk.lines =
            removed.map { DiffLine(kind: .removed, text: "-", oldNumber: $0, newNumber: nil) }
            + added.map { DiffLine(kind: .added, text: "+", oldNumber: nil, newNumber: $0) }
        var file = FileDiff(oldPath: "Order.cs", newPath: "Order.cs", status: .modified)
        file.hunks = [hunk]
        return file
    }

    private let old = [
        SyntaxScope(lines: 0...29, name: "Order"), SyntaxScope(lines: 2...9, name: "Handle"),
        SyntaxScope(lines: 12...15, name: "Total"), SyntaxScope(lines: 20...25, name: "Legacy"),
    ]
    private let new = [
        SyntaxScope(lines: 0...39, name: "Order"), SyntaxScope(lines: 2...9, name: "Handle"),
        SyntaxScope(lines: 12...25, name: "Total"), SyntaxScope(lines: 30...35, name: "Validate"),
    ]

    @Test func eachTouchedDefinitionSaysHowItChanged() {
        let entries = Outline.entries(
            of: diff(removed: [3] + Array(21...26), added: [3] + Array(15...24) + Array(31...36)),
            syntax: FileSyntax(oldScopes: old, newScopes: new))

        #expect(
            entries == [
                OutlineEntry(change: .signature, path: ["Order", "Handle"], line: 3),
                OutlineEntry(
                    change: .body, path: ["Order", "Total"], line: 15, lengths: (4, 14)),
                OutlineEntry(
                    change: .removed, path: ["Order", "Legacy"], line: 21, isOldSide: true),
                OutlineEntry(change: .added, path: ["Order", "Validate"], line: 31),
            ])
    }

    @Test func anAddedTypeIsOneEntryNotOneForEachOfItsMethods() {
        let added = [
            SyntaxScope(lines: 0...9, name: "Receipt"), SyntaxScope(lines: 2...4, name: "Print"),
        ]
        let entries = Outline.entries(
            of: diff(removed: [], added: Array(1...10)),
            syntax: FileSyntax(oldScopes: [], newScopes: added))
        #expect(entries == [OutlineEntry(change: .added, path: ["Receipt"], line: 1)])
    }

    @Test func sameNamedOverloadsAreMatchedInOrder() {
        let overloads = [
            SyntaxScope(lines: 0...2, name: "Add"), SyntaxScope(lines: 4...6, name: "Add"),
        ]
        let entries = Outline.entries(
            of: diff(removed: [6], added: [6]),
            syntax: FileSyntax(oldScopes: overloads, newScopes: overloads))
        #expect(entries == [OutlineEntry(change: .body, path: ["Add"], line: 6)])
    }
}
