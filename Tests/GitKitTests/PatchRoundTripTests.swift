import Foundation
import TestSupport
import Testing

@testable import GitKit

/// Property: applying the parsed hunks of `git diff old new` to `old` reproduces `new`.
@Suite struct PatchRoundTripTests {
    static let cases = 500

    @Test func parsedHunksReproduceTheNewFile() async throws {
        let seed =
            UInt64(ProcessInfo.processInfo.environment["SEAM_SEED"] ?? "")
            ?? UInt64.random(in: 1...UInt64.max)
        var random = SplitMix64(seed: seed)
        let directory = try TemporaryDirectory()
        let git = HermeticGit(home: directory.url)
        let old = directory.url.appending(path: "old")
        let new = directory.url.appending(path: "new")

        for index in 0..<Self.cases {
            let before = randomFile(&random)
            let after = mutate(before, &random)
            try before.write(to: old)
            try after.write(to: new)
            let patch = try await diffNoIndex(git, old, new, in: directory.url)
            let files = try PatchParser.parse(patch)
            let rebuilt = apply(files.first?.hunks ?? [], to: before)
            #expect(
                String(decoding: rebuilt, as: UTF8.self) == String(decoding: after, as: UTF8.self),
                "case \(index), seed \(seed) (rerun with SEAM_SEED=\(seed))\nold: \(String(decoding: before, as: UTF8.self).debugDescription)\nnew: \(String(decoding: after, as: UTF8.self).debugDescription)\ngot: \(String(decoding: rebuilt, as: UTF8.self).debugDescription)"
            )
            if rebuilt != after { return }
        }
    }

    private func diffNoIndex(_ git: HermeticGit, _ old: URL, _ new: URL, in directory: URL)
        async throws -> Data
    {
        let output = directory.appending(path: "out.patch")
        let arguments = [
            "diff", "--no-index", "--no-color", "--histogram", "-U2", "--output=\(output.path)",
            "--",
            old.lastPathComponent, new.lastPathComponent,
        ]
        // `--no-index` exits 1 whenever the files differ.
        do { _ = try await git.run(arguments, in: directory) } catch {
            guard case .nonZeroExit(_, 1, _) = error else { throw error }
        }
        return try Data(contentsOf: output)
    }

    private func randomFile(_ random: inout SplitMix64) -> Data {
        let words = [
            "alpha", "beta", "", "  indented", "{", "}", "return x", "diff --git a b", "-- dash",
            "+plus", "@@",
        ]
        let count = Int(random.next() % 30)
        var lines = (0..<count).map { _ in words[Int(random.next() % UInt64(words.count))] }
        if random.next() % 5 == 0 { lines = lines.map { $0 + "\r" } }
        var text = lines.joined(separator: "\n")
        if !lines.isEmpty && random.next() % 4 != 0 { text += "\n" }
        return Data(text.utf8)
    }

    private func mutate(_ data: Data, _ random: inout SplitMix64) -> Data {
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        for _ in 0..<Int(1 + random.next() % 4) {
            let position = Int(random.next() % UInt64(lines.count + 1))
            let choice = random.next() % 3
            if choice == 0 || position == lines.count {
                lines.insert("inserted \(random.next() % 100)", at: position)
            } else if choice == 1 {
                lines.remove(at: position)
            } else {
                lines[position] = "changed \(random.next() % 100)"
            }
        }
        if random.next() % 6 == 0, lines.last == "" { lines.removeLast() }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// Rebuilds the new file from the old one and the hunks, honouring the no-newline markers.
    private func apply(_ hunks: [Hunk], to data: Data) -> Data {
        var old = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        let oldEndsWithNewline = data.last == UInt8(ascii: "\n")
        if oldEndsWithNewline || data.isEmpty { old.removeLast() }
        var output: [String] = []
        var cursor = 0
        var lastNewSide: DiffLine?
        for hunk in hunks {
            let start = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
            output += old[cursor..<start]
            cursor = start
            for line in hunk.lines {
                if line.kind != .added { cursor += 1 }
                if line.kind != .removed {
                    output.append(line.text)
                    lastNewSide = line
                }
            }
        }
        let tailCopied = cursor < old.count
        output += old[cursor...]
        let newEndsWithNewline =
            tailCopied ? oldEndsWithNewline : !(lastNewSide?.noNewlineAtEnd ?? !oldEndsWithNewline)
        guard !output.isEmpty else { return Data() }
        return Data((output.joined(separator: "\n") + (newEndsWithNewline ? "\n" : "")).utf8)
    }
}

struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
