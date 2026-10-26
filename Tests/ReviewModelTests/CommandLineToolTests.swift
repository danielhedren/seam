import Foundation
import SeamCore
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

@Suite(.timeLimit(.minutes(1))) struct CommandLineToolTests {
    /// Any file stands in for the command; install only links to it.
    private static let script = URL(fileURLWithPath: #filePath)

    @Test func installLinksTheScriptAndLeavesOtherFilesAlone() throws {
        let directory = try TemporaryDirectory()
        let link = directory.resolved.appending(path: "bin/seam")

        try CommandLineTool.install(script: Self.script, at: link)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == Self.script.path
        )
        try CommandLineTool.install(script: Self.script, at: link)

        let foreign = directory.resolved.appending(path: "bin/foreign")
        try FileManager.default.createSymbolicLink(
            at: foreign, withDestinationURL: URL(fileURLWithPath: "/usr/local/bin/someone-else"))
        #expect(throws: CommandLineTool.Failure.occupied(foreign.path)) {
            try CommandLineTool.install(script: Self.script, at: foreign)
        }

        let other = directory.resolved.appending(path: "bin/other")
        try Data("mine".utf8).write(to: other)
        #expect(throws: CommandLineTool.Failure.occupied(other.path)) {
            try CommandLineTool.install(script: Self.script, at: other)
        }
    }

    @Test func failuresSayWhatWentWrongInWords() {
        let missing = CommandLineTool.Failure.missingScript.localizedDescription
        #expect(missing.contains("seam command"), "\(missing)")
        let occupied = CommandLineTool.Failure.occupied("/x/seam").localizedDescription
        #expect(occupied.hasPrefix("/x/seam already exists"), "\(occupied)")
    }
}
