import Foundation
import TestSupport
import Testing

@testable import Features

@Suite struct CommandLineToolTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "App/Seam/seam")

    @Test func urlsRoundTripPathsAndBases() throws {
        let request = SeamURL(path: "/Users/me/my repo/a&b=c#d", base: "origin/feat/x y")
        let url = try #require(request.url)
        #expect(SeamURL(url) == request)
        #expect(SeamURL(try #require(URL(string: "seam://open?path=/r"))) == SeamURL(path: "/r"))
        #expect(SeamURL(try #require(URL(string: "seam://other?path=/r"))) == nil)
        #expect(SeamURL(try #require(URL(string: "seam://open"))) == nil)
    }

    /// The real script, with a fake `open` first on PATH that prints the URL it was given.
    @Test func theScriptEncodesWhatTheAppParses() async throws {
        let directory = try TemporaryDirectory()
        let bin = directory.resolved.appending(path: "bin")
        let repo = directory.resolved.appending(path: "my repo & co")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let fake = bin.appending(path: "open")
        try Data("#!/bin/sh\nprintf '%s' \"$3\"\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let process = Process()
        process.executableURL = Self.script
        process.arguments = [repo.path, "--base", "origin/feat/ü x"]
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let printed = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationStatus == 0)
        let request = try #require(URL(string: printed).flatMap(SeamURL.init))
        #expect(request == SeamURL(path: repo.path, base: "origin/feat/ü x"))
    }

    @Test func installLinksTheScriptAndLeavesOtherFilesAlone() throws {
        let directory = try TemporaryDirectory()
        let link = directory.resolved.appending(path: "bin/seam")

        try CommandLineTool.install(script: Self.script, at: link)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == Self.script.path
        )
        try CommandLineTool.install(script: Self.script, at: link)

        let other = directory.resolved.appending(path: "bin/other")
        try Data("mine".utf8).write(to: other)
        #expect(throws: CommandLineTool.Failure.occupied(other.path)) {
            try CommandLineTool.install(script: Self.script, at: other)
        }
    }
}
