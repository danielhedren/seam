import Foundation

/// Installs the bundled `seam` script as a symlink in `~/.local/bin` (SPEC §13). A symlink, so
/// updating the app updates the command.
enum CommandLineTool {
    enum Failure: LocalizedError, Equatable {
        /// Something that isn't our symlink is already there; we don't replace it.
        case occupied(String)
        case missingScript

        var errorDescription: String? {
            switch self {
            case .occupied(let path):
                String(
                    localized: "\(path) already exists and isn't Seam's. Remove it and try again.",
                    bundle: .module)
            case .missingScript:
                String(
                    localized:
                        "This copy of Seam doesn't include the seam command. Build it with make app or make install.",
                    bundle: .module)
            }
        }
    }

    static var defaultLink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/seam")
    }

    static func install(script: URL?, at link: URL = defaultLink) throws {
        guard let script else { throw Failure.missingScript }
        let manager = FileManager.default
        if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            guard existing != script.path else { return }
            // Another copy of Seam's own script (the app moved) may be replaced; anything else not.
            guard existing.hasSuffix(".app/Contents/Resources/seam") else {
                throw Failure.occupied(link.path)
            }
            try manager.removeItem(at: link)
        } else if manager.fileExists(atPath: link.path) {
            throw Failure.occupied(link.path)
        }
        try manager.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: link, withDestinationURL: script)
    }
}
