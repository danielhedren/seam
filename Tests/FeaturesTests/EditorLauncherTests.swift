import Foundation
import TestSupport
import Testing

@testable import Features

@Suite(.timeLimit(.minutes(1))) struct ShellLauncherTests {
    private let launcher = ShellLauncher(shell: URL(fileURLWithPath: "/bin/sh"))

    @Test func aFailingCommandReportsWhatItPrinted() async {
        await #expect(throws: LaunchFailed(message: "no such editor")) {
            try await launcher.run("echo 'no such editor' >&2; exit 3")
        }
    }

    /// A full pipe once deadlocked a child that wrote more than its buffer; it must finish.
    @Test func aChattyCommandThatSucceedsIsFine() async throws {
        await #expect(throws: Never.self) {
            try await launcher.run("head -c 200000 /dev/zero >&2")
        }
    }

    /// A login shell whose startup files never return gives up after the timeout and falls back
    /// to the usual folders, by the injected clock.
    @Test func aShellThatHangsFallsBackToTheUsualPath() async throws {
        let shell = Scratch.path("seam-hanging-shell")
        try Data("#!/bin/sh\nexec sleep 60\n".utf8).write(to: shell)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let clock = ManualClock()
        let reader = LoginShellPath(clock: clock)
        let path = Task { await reader.value(shell: shell) }
        await clock.sleepers()
        clock.advance(by: LoginShellPath.timeout)
        #expect(await path.value.hasSuffix(":/opt/homebrew/bin:/usr/local/bin"))
    }

    @Test func aMissingCommandSaysSoWithoutTheShellsNoise() async {
        await #expect(
            throws: LaunchFailed(
                message:
                    "seam-no-such-editor isn't installed or isn't on your PATH. Choose your editor in Settings."
            )
        ) {
            try await launcher.run("seam-no-such-editor '/a b':1")
        }
    }

    @Test func aPresetMissingFromPathRunsTheToolInsideItsApp() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let tool = app.appending(path: "Contents/MacOS/cli")
        let bin = app.appending(path: "bin")
        defer { try? FileManager.default.removeItem(at: app) }
        for executable in [tool, bin.appending(path: "zed")] {
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(
                FileManager.default.createFile(
                    atPath: executable.path, contents: Data("#!/bin/sh\n".utf8),
                    attributes: [.posixPermissions: 0o755]))
        }
        var launcher = launcher
        launcher.locateApp = { $0 == "dev.zed.Zed" ? app : nil }
        #expect(
            launcher.resolve("zed '/w/a.swift':3", path: "/nowhere")
                == EditorCommand.quoted(tool.path) + " '/w/a.swift':3")
        #expect(
            launcher.resolve("zed '/w/a.swift':3", path: "/nowhere:" + bin.path)
                == "zed '/w/a.swift':3")
    }
}

@Suite(.timeLimit(.minutes(1))) struct EditorCommandTests {
    @Test func theDefaultIsTheFirstInstalledPreset() {
        #expect(
            EditorCommand.installedDefault {
                $0 == "com.microsoft.VSCode" ? URL(filePath: "/A") : nil
            }
                == "code -g {path}:{line}")
        #expect(EditorCommand.installedDefault { _ in nil } == EditorCommand.zed)
    }

    @Test func pathsAreQuotedSoSpacesAndQuotesStayOneArgument() {
        let line = EditorCommand(template: "code -g {path}:{line}").commandLine(
            path: "/w/a b/it's.swift", line: 42)
        #expect(line == "code -g '/w/a b/it'\\''s.swift':42")
    }
}
