import Foundation
import Testing

@testable import GitKit

@Suite struct ProcessRunnerTests {
    /// git exits without reading its input, so the write hits a closed pipe. Without
    /// F_SETNOSIGPIPE that raises SIGPIPE and kills the whole app (and this test process).
    @Test func aCommandThatIgnoresItsInputDoesNotKillTheProcess() async throws {
        let input = Data(repeating: UInt8(ascii: "x"), count: 8_000_000)
        let output = try await CLIGitClient().run(
            ["version"], in: URL(fileURLWithPath: "/"), input: input)
        #expect(String(decoding: output, as: UTF8.self).hasPrefix("git version"))
    }

}
