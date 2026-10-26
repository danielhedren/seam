#if os(Linux)
    import Foundation
    import Glibc
    import GitKit
    import Synchronization

    /// The Linux watcher (ADR 0007). inotify watches one directory at a time, so the tree is walked
    /// and directories are added as they appear. Inside a git dir only what `ChangeClassifier`
    /// reads is watched; `node_modules` and `.build` are skipped, being large and nearly always
    /// ignored. An overflowed queue reports the roots, which refreshes everything, and walks the
    /// tree again for folders whose events were lost.
    public struct InotifyWatcher: FileWatcher {
        public init() {}

        public func events(for directories: [URL]) -> AsyncStream<[String]> {
            AsyncStream { continuation in
                guard let session = InotifySession(directories.map(\.path), continuation) else {
                    continuation.finish()
                    return
                }
                continuation.onTermination = { _ in session.stop() }
                Thread { session.run() }.start()
            }
        }
    }

    // `watches` is filled in init, before the reader thread starts, and only that thread touches
    // it afterwards; stop() only takes `wakeOpen`'s lock.
    private final class InotifySession: @unchecked Sendable {
        private static let mask = UInt32(
            IN_CREATE | IN_DELETE | IN_MODIFY | IN_ATTRIB | IN_MOVED_FROM | IN_MOVED_TO
                | IN_MOVE_SELF | IN_DONT_FOLLOW | IN_EXCL_UNLINK)
        private static let skipped: Set<String> = ["node_modules", ".build"]
        private static let skippedInGitDirectory: Set<String> = [
            "objects", "logs", "modules", "lfs",
        ]

        private let descriptor: Int32
        private let wake: (read: Int32, write: Int32)
        private let roots: [String]
        private let continuation: AsyncStream<[String]>.Continuation
        private var watches: [Int32: String] = [:]
        private var full = false
        /// Cleared when the reader closes the pipe, so a late stop() can't write to a reused fd.
        private let wakeOpen = Mutex(true)
        private let logger = Logger(subsystem: "com.danielhedren.seam", category: "SeamCore")

        init?(_ roots: [String], _ continuation: AsyncStream<[String]>.Continuation) {
            var pipe: [Int32] = [0, 0]
            let descriptor = inotify_init1(Int32(IN_CLOEXEC))
            guard descriptor >= 0 else { return nil }
            guard Glibc.pipe(&pipe) == 0 else {
                close(descriptor)
                return nil
            }
            self.descriptor = descriptor
            wake = (pipe[0], pipe[1])
            self.roots = roots.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            self.continuation = continuation
            // Every root before any subfolder, so a full watch limit never leaves a root out.
            for root in self.roots { _ = watch(root) }
            for root in self.roots { _ = addTree(root, rootWatched: true) }
        }

        func stop() {
            wakeOpen.withLock { open in
                var byte: UInt8 = 0
                if open { _ = write(wake.write, &byte, 1) }
            }
        }

        func run() {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                var fds = [
                    pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0),
                ]
                if poll(&fds, 2, -1) < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if fds[1].revents != 0 { break }
                let count = buffer.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { break }
                let paths = parse(buffer, count: count)
                if !paths.isEmpty { continuation.yield(paths) }
            }
            close(descriptor)
            wakeOpen.withLock { open in
                open = false
                close(wake.read)
                close(wake.write)
            }
            continuation.finish()
        }

        private func parse(_ buffer: [UInt8], count: Int) -> [String] {
            let header = MemoryLayout<inotify_event>.size
            var paths: [String] = []
            var offset = 0
            while offset + header <= count {
                let (wd, mask, length) = buffer.withUnsafeBytes { raw in
                    (
                        raw.loadUnaligned(fromByteOffset: offset, as: Int32.self),
                        raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self),
                        Int(raw.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self))
                    )
                }
                let start = offset + header
                offset = start + length
                let name = String(
                    decoding: buffer[start..<min(start + length, count)].prefix { $0 != 0 },
                    as: UTF8.self)
                if mask & UInt32(IN_Q_OVERFLOW) != 0 {
                    for root in roots { _ = addTree(root, rootWatched: true) }
                    paths += roots
                    continue
                }
                if mask & UInt32(IN_IGNORED) != 0 {
                    watches[wd] = nil
                    continue
                }
                guard let directory = watches[wd] else { continue }
                if mask & UInt32(IN_MOVE_SELF) != 0 {
                    // Moved within the roots, its new parent's IN_MOVED_TO came first and renamed
                    // the watch; still at its old name, it went elsewhere.
                    if !exists(directory) { unwatch(directory) }
                    continue
                }
                let path = name.isEmpty ? directory : directory + "/" + name
                if mask & UInt32(IN_ISDIR) != 0, mask & UInt32(IN_CREATE | IN_MOVED_TO) != 0 {
                    paths += addTree(path, rootWatched: false)
                }
                paths.append(path)
            }
            return paths
        }

        /// Breadth first, so when the watch limit runs out the shallow folders are the ones kept.
        /// Returns what the walk found: anything made before its folder's watch has no event.
        private func addTree(_ root: String, rootWatched: Bool) -> [String] {
            var queue = [root]
            var found: [String] = []
            var index = 0
            while index < queue.count {
                let directory = queue[index]
                index += 1
                if directory != root || !rootWatched, !watch(directory) { return found }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
                let isGitDirectory = names.contains("HEAD") && names.contains("refs")
                for name in names where !Self.skipped.contains(name) {
                    if isGitDirectory, Self.skippedInGitDirectory.contains(name) { continue }
                    let path = directory + "/" + name
                    found.append(path)
                    var info = stat()
                    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                        continue
                    }
                    queue.append(path)
                }
            }
            return found
        }

        private func exists(_ directory: String) -> Bool {
            var info = stat()
            return lstat(directory, &info) == 0
        }

        /// A folder and everything under it.
        private func unwatch(_ directory: String) {
            for (wd, path) in watches where path == directory || path.hasPrefix(directory + "/") {
                inotify_rm_watch(descriptor, wd)
                watches[wd] = nil
            }
        }

        /// False once the user's watch limit is reached; a folder that vanished is no failure.
        private func watch(_ directory: String) -> Bool {
            let wd = inotify_add_watch(descriptor, directory, Self.mask)
            if wd >= 0 {
                // A moved folder keeps its watch, so this may be a new name for an old one.
                watches[wd] = directory
                return true
            }
            guard errno == ENOSPC else { return true }
            if !full {
                full = true
                logger.error(
                    "inotify watch limit reached; deeper folders under \(directory) aren't watched")
            }
            return false
        }
    }
#endif
