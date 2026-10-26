import Foundation
import GitKit

#if canImport(AppKit)
    import AppKit
#endif

/// The editor command (SPEC §7.6): a template whose `{path}` and `{line}` are filled in.
package struct EditorCommand: Equatable, Sendable {
    static let zed = "zed {path}:{line}"
    package static let presets = [
        EditorPreset(
            name: "Zed", template: zed, bundleID: "dev.zed.Zed", bundledTool: "Contents/MacOS/cli"),
        EditorPreset(
            name: "VS Code", template: "code -g {path}:{line}", bundleID: "com.microsoft.VSCode",
            bundledTool: "Contents/Resources/app/bin/code"),
        EditorPreset(
            name: "Rider", template: "rider --line {line} {path}", bundleID: "com.jetbrains.rider",
            bundledTool: "Contents/MacOS/rider"),
        EditorPreset(
            name: "Cursor", template: "cursor -g {path}:{line}",
            bundleID: "com.todesktop.230313mzl4w4u92",
            bundledTool: "Contents/Resources/app/bin/cursor"),
    ]

    package var template = EditorCommand.zed

    /// The first preset whose app is installed, so a fresh install opens an editor the reader has.
    static func installedDefault(locate: (String) -> URL? = EditorPreset.locate) -> String {
        presets.first { locate($0.bundleID) != nil }?.template ?? zed
    }

    /// The shell command line: values are single-quoted, so paths with spaces or quotes stay one
    /// argument.
    func commandLine(path: String, line: Int) -> String {
        template
            .replacingOccurrences(of: "{path}", with: Self.quoted(path))
            .replacingOccurrences(of: "{line}", with: String(line))
    }

    package static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

package struct EditorPreset: Sendable {
    package var name: String
    package var template: String
    var bundleID: String
    /// The command-line tool inside the app, used when its shell command isn't installed.
    var bundledTool: String

    var command: String { String(template.prefix { $0 != " " }) }

    /// Editors are found as installed macOS apps; elsewhere only their shell commands are.
    @Sendable static func locate(_ bundleID: String) -> URL? {
        #if canImport(AppKit)
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        #else
            nil
        #endif
    }
}

package protocol CommandLauncher: Sendable {
    /// Runs `commandLine`; throws with the command's own output when it fails.
    func run(_ commandLine: String) async throws
}

package struct LaunchFailed: Error, Equatable {
    var message: String
}

/// Runs the command with `/bin/sh` and the PATH of the user's shell. Running the command in an
/// interactive shell instead would mix its startup files' complaints into every error.
package struct ShellLauncher: CommandLauncher {
    var shell = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    var locateApp: @Sendable (String) -> URL? = EditorPreset.locate
    private let searchPath = LoginShellPath()

    package func run(_ commandLine: String) async throws {
        let path = await searchPath.value(shell: shell)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        let result = try await Subprocess.run(
            URL(fileURLWithPath: "/bin/sh"), ["-c", resolve(commandLine, path: path)],
            environment: environment)
        switch result.status {
        case 0: return
        case 127:
            let command = String(commandLine.prefix { !$0.isWhitespace })
            throw LaunchFailed(
                message: String(
                    localized:
                        "\(command) isn't installed or isn't on your PATH. Choose your editor in Settings.",
                    bundle: .module))
        default:
            throw LaunchFailed(
                message: String(decoding: result.errors, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Swaps a preset's command for the tool inside its app when the command isn't on `path`;
    /// most people never run VS Code's "Install 'code' command in PATH".
    func resolve(_ commandLine: String, path: String) -> String {
        guard
            let preset = EditorCommand.presets.first(where: {
                commandLine.hasPrefix($0.command + " ")
            }),
            !Self.isOnPath(preset.command, path),
            let tool = locateApp(preset.bundleID)?.appending(path: preset.bundledTool).path,
            FileManager.default.isExecutableFile(atPath: tool)
        else { return commandLine }
        return EditorCommand.quoted(tool) + commandLine.dropFirst(preset.command.count)
    }

    static func isOnPath(_ command: String, _ path: String) -> Bool {
        path.split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/\(command)")
        }
    }
}

/// The PATH of the user's login, interactive shell, read once: an app started from Finder doesn't
/// get it, and many people set PATH in `.zshrc`.
package actor LoginShellPath {
    private static let marker = "__SEAM_PATH__="
    /// A startup file that never returns mustn't hold up the editor or gh for good.
    static let timeout = Duration.seconds(10)
    private var reading: Task<String, Never>?
    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    func value(shell: URL) async -> String {
        if let reading { return await reading.value }
        let reading = Task { [clock] in await Self.read(shell, clock: clock) }
        self.reading = reading
        return await reading.value
    }

    private static func read(_ shell: URL, clock: any Clock<Duration>) async -> String {
        let fallback =
            (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            + ":/opt/homebrew/bin:/usr/local/bin"
        // The marker skips whatever the startup files print themselves.
        guard
            let result = try? await Subprocess.run(
                shell, ["-l", "-i", "-c", "printf '\\n\(marker)%s\\n' \"$PATH\""],
                timeout: (timeout, clock)),
            let line = String(decoding: result.output, as: UTF8.self)
                .split(separator: "\n").last(where: { $0.hasPrefix(marker) })
        else { return fallback }
        return String(line.dropFirst(marker.count))
    }
}

private enum Subprocess {
    struct Result {
        package var status: Int32
        var output: Data
        var errors: Data
    }

    /// Through GitKit's runner, which launches safely on Linux too; a timeout cancels the run,
    /// which terminates the process.
    package static func run(
        _ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
        timeout: (Duration, any Clock<Duration>)? = nil
    ) async throws -> Result {
        let work = Task {
            try await ProcessRunner.run(
                executable: executable, arguments: arguments,
                directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                environment: environment ?? ProcessInfo.processInfo.environment, input: nil)
        }
        let watchdog = timeout.map { timeout, clock in
            Task {
                try await clock.sleep(for: timeout)
                work.cancel()
            }
        }
        defer { watchdog?.cancel() }
        let result = try await work.value
        return Result(status: result.status, output: result.stdout, errors: result.stderr)
    }
}
