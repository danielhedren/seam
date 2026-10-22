import Foundation
import SeamCore
import TestSupport
import Testing

@testable import Features

@Suite struct CommandLineToolTests {
    /// Any file stands in for the command; install only links to it.
    private static let script = URL(fileURLWithPath: #filePath)

    @Test func urlsRoundTripPathsAndBases() throws {
        // What the seam command builds, the app must read back, whatever the path holds.
        let request = SeamURL(path: "/Users/me/my repo/a&b=c#d+ü", base: "origin/feat/ü x")
        let url = try #require(request.url)
        #expect(SeamURL(url) == request)
        #expect(SeamURL(try #require(URL(string: "seam://open?path=/r"))) == SeamURL(path: "/r"))
        #expect(SeamURL(try #require(URL(string: "seam://other?path=/r"))) == nil)
        #expect(SeamURL(try #require(URL(string: "seam://open"))) == nil)
    }

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
}
