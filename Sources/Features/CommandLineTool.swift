import Foundation

/// Installs the bundled `seam` script as a symlink in `~/.local/bin` (SPEC §13). A symlink, so
/// updating the app updates the command.
enum CommandLineTool {
    enum Failure: Error, Equatable {
        /// Something that isn't our symlink is already there; we don't replace it.
        case occupied(String)
        case missingScript
    }

    static var defaultLink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/seam")
    }

    static func install(script: URL?, at link: URL = defaultLink) throws {
        guard let script else { throw Failure.missingScript }
        let manager = FileManager.default
        if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            guard existing != script.path else { return }
            try manager.removeItem(at: link)
        } else if manager.fileExists(atPath: link.path) {
            throw Failure.occupied(link.path)
        }
        try manager.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: script)
    }
}
