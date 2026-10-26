#if !canImport(Darwin)
    import Foundation
    import Glibc
    import Synchronization

    /// Foundation's `Process.run()` on Linux can crash at random: it over-reads `readdir`'s
    /// buffer while scanning /proc/self/fd (swift-corelibs-foundation #5472, not in 6.4). So
    /// Linux spawns with posix_spawn directly.
    extension ProcessRunner {
        /// Linux has no per-pipe flag, so SIGPIPE is ignored for the whole process, once.
        static let ignoreSIGPIPE: Void = { _ = signal(SIGPIPE, SIG_IGN) }()

        /// Held from making a launch's pipes until its child has them, so no other launch can
        /// inherit an end before it's marked close-on-exec and keep that pipe open.
        private static let spawning = Mutex(())

        package static func run(
            executable: URL,
            arguments: [String],
            directory: URL,
            environment: [String: String],
            input: Data?
        ) async throws -> ProcessResult {
            try Task.checkCancellation()
            ProcessRunner.ignoreSIGPIPE
            let pid = try spawning.withLock { _ in
                try spawn(executable, arguments, directory, environment, input != nil)
            }
            // A cancel that lands before the spawn finds nothing running to terminate.
            if Task.isCancelled { kill(pid.id, SIGTERM) }
            return try await withTaskCancellationHandler {
                // Drain both pipes and feed stdin concurrently, or a full pipe buffer deadlocks git.
                async let out = Task.detached { pid.stdout.readDataToEndOfFile() }.value
                async let err = Task.detached { pid.stderr.readDataToEndOfFile() }.value
                async let wrote: Void = Task.detached {
                    guard let writer = pid.stdin else { return }
                    if let input { try? writer.write(contentsOf: input) }
                    try? writer.close()
                }.value
                let status = await Task.detached { waitForExit(pid.id) }.value
                await wrote
                let result = ProcessResult(status: status, stdout: await out, stderr: await err)
                try Task.checkCancellation()
                return result
            } onCancel: {
                kill(pid.id, SIGTERM)
            }
        }

        private struct Spawned: Sendable {
            var id: pid_t
            var stdout: FileHandle
            var stderr: FileHandle
            var stdin: FileHandle?
        }

        private static func spawn(
            _ executable: URL, _ arguments: [String], _ directory: URL,
            _ environment: [String: String], _ feedsInput: Bool
        ) throws -> Spawned {
            let stdout = try pipe()
            let stderr = try pipe()
            let stdin = feedsInput ? try pipe() : nil
            var actions = posix_spawn_file_actions_t()
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            if let stdin {
                posix_spawn_file_actions_adddup2(&actions, stdin.read, 0)
            } else {
                posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            }
            posix_spawn_file_actions_adddup2(&actions, stdout.write, 1)
            posix_spawn_file_actions_adddup2(&actions, stderr.write, 2)
            posix_spawn_file_actions_addchdir_np(&actions, directory.absoluteURL.path)
            // Descriptors opened elsewhere without close-on-exec (a file being written, say) must not
            // reach the child: one held open there makes executing that file fail with ETXTBSY.
            posix_spawn_file_actions_addclosefrom_np(&actions, 3)

            let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { for pointer in argv + envp { free(pointer) } }
            // The child starts with every signal unblocked and at its default, as Process does:
            // pool threads block signals, and this process ignores SIGPIPE.
            var attributes = posix_spawnattr_t()
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            var unblocked = sigset_t()
            sigemptyset(&unblocked)
            posix_spawnattr_setsigmask(&attributes, &unblocked)
            var every = sigset_t()
            sigfillset(&every)
            posix_spawnattr_setsigdefault(&attributes, &every)
            posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
            var pid = pid_t()
            let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
            // The child has its own copies now; ours would keep the pipes from reaching EOF.
            close(stdout.write)
            close(stderr.write)
            if let stdin { close(stdin.read) }
            guard status == 0 else {
                close(stdout.read)
                close(stderr.read)
                if let stdin { close(stdin.write) }
                throw SpawnError(path: executable.path, code: status)
            }
            return Spawned(
                id: pid,
                stdout: FileHandle(fileDescriptor: stdout.read, closeOnDealloc: true),
                stderr: FileHandle(fileDescriptor: stderr.read, closeOnDealloc: true),
                stdin: stdin.map { FileHandle(fileDescriptor: $0.write, closeOnDealloc: true) })
        }

        private static func pipe() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [0, 0]
            guard Glibc.pipe(&fds) == 0 else { throw SpawnError(path: "pipe", code: errno) }
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (fds[0], fds[1])
        }

        /// The exit status, or the signal that ended it, as Foundation's `terminationStatus`.
        private static func waitForExit(_ pid: pid_t) -> Int32 {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 {
                if errno != EINTR { return -1 }
            }
            let signal = status & 0x7f
            return signal == 0 ? (status >> 8) & 0xff : signal
        }
    }

    struct SpawnError: Error, CustomStringConvertible {
        var path: String
        var code: Int32
        var description: String { "\(path): \(String(cString: strerror(code)))" }
    }
#endif
