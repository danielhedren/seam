import Foundation
import TestSupport
import Testing

@testable import SeamCore

/// Property (SPEC §7.7): edits around a thread's lines never put it on the wrong lines. Wherever
/// `locate` lands, the file says what the thread quoted; and when its lines are unique and
/// untouched, it lands where the edits moved them.
@Suite(.timeLimit(.minutes(1)))
struct ThreadAnchorPropertyTests {
    static let cases = 2000

    @Test func editsAroundTheLinesNeverMoveAThreadOntoOthers() {
        let seed = SplitMix64.seed()
        var random = SplitMix64(seed: seed)
        for index in 0..<Self.cases {
            // A small vocabulary makes repeated lines, and so ambiguous places, common.
            let unique = Bool.random(using: &random)
            let count = Int.random(in: 3...30, using: &random)
            var file = (0..<count).map { line in
                unique ? "line \(line)" : "word \(Int.random(in: 0..<4, using: &random))"
            }
            let length = Int.random(in: 1...min(3, count), using: &random)
            let start = Int.random(in: 0...(count - length), using: &random)
            let anchor = ThreadAnchor(
                path: "a", side: .new, lines: (start + 1)...(start + length),
                text: Array(file[start..<(start + length)]))

            var position = start
            for edit in 0..<Int.random(in: 0...6, using: &random) {
                let before = Bool.random(using: &random)
                let insert = Bool.random(using: &random)
                if insert {
                    let at =
                        before
                        ? Int.random(in: 0...position, using: &random)
                        : Int.random(in: (position + length)...file.count, using: &random)
                    file.insert("new \(index).\(edit)", at: at)
                    if before { position += 1 }
                } else if before, position > 0 {
                    file.remove(at: Int.random(in: 0..<position, using: &random))
                    position -= 1
                } else if !before, position + length < file.count {
                    file.remove(
                        at: Int.random(in: (position + length)..<file.count, using: &random))
                }
            }

            let found = anchor.locate(in: file.map { Substring($0) })
            if let found {
                let text = Array(file[(found.lowerBound - 1)..<found.upperBound])
                #expect(text == anchor.text, "case \(index), seed \(seed)")
            }
            if unique {
                #expect(
                    found == (position + 1)...(position + length), "case \(index), seed \(seed)")
            }
        }
    }
}
