import Foundation

/// The editor command (SPEC §7.6): a template whose `{path}` and `{line}` are filled in.
struct EditorCommand: Equatable, Sendable {
    static let zed = "zed {path}:{line}"
    static let presets: [(name: String, template: String)] = [
        ("Zed", zed), ("VS Code", "code -g {path}:{line}"),
        ("Rider", "rider --line {line} {path}"), ("Cursor", "cursor -g {path}:{line}"),
    ]

    var template = EditorCommand.zed

    /// The shell command line: values are single-quoted, so paths with spaces or quotes stay one
    /// argument.
    func commandLine(path: String, line: Int) -> String {
        template
            .replacingOccurrences(of: "{path}", with: Self.quoted(path))
            .replacingOccurrences(of: "{line}", with: String(line))
    }

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

protocol CommandLauncher: Sendable {
    /// Runs `commandLine`; throws with the command's own output when it fails.
    func run(_ commandLine: String) async throws
}

struct LaunchFailed: Error, Equatable {
    var message: String
}

/// Runs through the user's login shell: an app started from Finder doesn't get the shell's PATH,
/// where editor command-line tools usually live.
struct ShellLauncher: CommandLauncher {
    func run(_ commandLine: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", commandLine]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            throw LaunchFailed(
                message: String(decoding: output, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
