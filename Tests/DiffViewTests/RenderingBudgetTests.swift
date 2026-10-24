import AppKit
import Foundation
import GitKit
import SeamCore
import Testing

@testable import DiffView

/// SPEC §8.7 rendering budgets on a synthetic 20k-line diff. Run with `make test-all`.
@MainActor
@Suite(
    .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["SEAM_BENCH"] != nil))
struct RenderingBudgetTests {
    /// 50 files of 400 changed lines each: alternating blocks of context, removals and additions.
    static func syntheticPatch() -> Data {
        var patch = ""
        for file in 0..<50 {
            patch += "diff --git a/src/File\(file).swift b/src/File\(file).swift\n"
            patch += "index 1111111..2222222 100644\n--- a/src/File\(file).swift\n"
            patch += "+++ b/src/File\(file).swift\n"
            for block in 0..<20 {
                let start = block * 30 + 1
                patch += "@@ -\(start),15 +\(start),15 @@ func block\(block)() {\n"
                for line in 0..<10 {
                    patch +=
                        "     let value\(line) = compute(\(line), offset: \(block)) // context\n"
                }
                for line in 0..<5 {
                    patch += "-    let old\(line) = legacyValue(\(line), \"string \(line)\")\n"
                }
                for line in 0..<5 {
                    patch += "+    let new\(line) = currentValue(\(line), \"string \(line)\")\n"
                }
            }
        }
        return Data(patch.utf8)
    }

    private static func content() throws -> DiffContent {
        let review = ReviewDiff(
            scope: .all, files: try PatchParser.parse(syntheticPatch()).map { ReviewFile(diff: $0) }
        )
        // Spans every few characters, like real highlighting, so drawing pays for colours.
        let spans = stride(from: 0, to: 60, by: 6).map {
            SyntaxSpan(range: $0..<($0 + 4), token: .keyword)
        }
        let lines = Array(repeating: spans, count: 700)
        var syntax: [String: FileSyntax] = [:]
        for file in review.files { syntax[file.diff.path] = FileSyntax(old: lines, new: lines) }
        return DiffContent(review: review, syntax: syntax)
    }

    private func render(_ view: NSView) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    @Test func firstPaintOfA20kLineDiffIsWithin500ms() throws {
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let content = try Self.content()
            #expect(
                content.review.files.reduce(0) {
                    $0 + $1.diff.hunks.reduce(0) { $0 + $1.lines.count }
                } == 20_000)
            let view = DiffScrollView()
            view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            view.show(content, position: .top)
            view.layoutSubtreeIfNeeded()
            render(view)
        }
        #expect(elapsed < .milliseconds(500), "first paint took \(elapsed)")
    }

    @Test(arguments: [DiffLayoutMode.unified, .split])
    func scrollingDrawsEachFrameWithin8ms(mode: DiffLayoutMode) throws {
        var content = try Self.content()
        content.mode = mode
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        view.show(content, position: .top)
        view.layoutSubtreeIfNeeded()
        render(view)
        let clock = ContinuousClock()
        var frames: [Duration] = []
        for _ in 0..<200 {
            frames.append(
                clock.measure {
                    // About 2 rows per frame at 120 Hz is a brisk scroll; every frame meets new rows.
                    view.page(by: 1)
                    view.contentView.scroll(
                        to: NSPoint(x: 0, y: view.contentView.bounds.minY - 750))
                    render(view)
                })
        }
        frames.sort()
        let median = frames[frames.count / 2]
        let worst = frames[frames.count * 95 / 100]
        #expect(worst < .milliseconds(8), "\(mode): median \(median), 95th percentile \(worst)")
    }

    /// `v` collapses the file it marks, so this is the cost of a keypress.
    @Test func collapsingAFileOfA20kLineDiffTakesUnder8ms() throws {
        var content = try Self.content()
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        view.show(content, position: .top)
        let clock = ContinuousClock()
        var times: [Duration] = []
        for file in content.review.files.prefix(20) {
            content.collapsed.insert(file.diff.path)
            let shown = content
            times.append(clock.measure { view.show(shown, position: .keep) })
        }
        times.sort()
        #expect(times[times.count / 2] < .milliseconds(8), "median \(times[times.count / 2])")
    }
}
