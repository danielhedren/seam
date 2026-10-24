import Foundation
import Testing

@testable import Features

@Suite(.timeLimit(.minutes(1))) struct ShellLauncherTests {
    private let launcher = ShellLauncher(shell: URL(fileURLWithPath: "/bin/sh"))

    @Test func aFailingCommandReportsWhatItPrinted() async {
        await #expect(throws: LaunchFailed(message: "no such editor")) {
            try await launcher.run("echo 'no such editor' >&2; exit 3")
        }
    }

    @Test func aChattyCommandThatSucceedsIsFine() async throws {
        try await launcher.run("head -c 200000 /dev/zero >&2")
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
