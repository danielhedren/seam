import AppKit
import GitKit
import SeamCore
import SnapshotTesting
import Testing

@testable import DiffView

/// SPEC §10: image snapshots of the diff view. Rendering differs between macOS releases, so each
/// major version keeps its own references. Record with `SNAPSHOT_TESTING_RECORD=all swift test`.
@MainActor
@Suite(.snapshots(record: .missing))
struct DiffSnapshotTests {
    private static let os = "macOS\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"

    private static func line(_ kind: DiffLine.Kind, _ text: String, _ old: Int?, _ new: Int?)
        -> DiffLine
    {
        DiffLine(kind: kind, text: text, oldNumber: old, newNumber: new)
    }

    private static let review: ReviewDiff = {
        var first = Hunk(
            oldStart: 8, oldCount: 6, newStart: 8, newCount: 7, section: "struct Order {")
        first.lines = [
            line(.context, "    var id: UUID", 8, 8),
            line(.removed, "    var total: Int", 9, nil),
            line(.removed, "    var currency = \"SEK\"", 10, nil),
            line(.added, "    var total: Decimal", nil, 9),
            line(.added, "    var currency: Currency", nil, 10),
            line(.added, "    var lines: [OrderLine] = []", nil, 11),
            line(.context, "", 11, 12),
            line(.context, "    func validate() throws {", 12, 13),
            line(
                .context,
                "\tguard total >= 0 else { throw OrderError.negativeTotal(total, currency: currency) }",
                13, 14),
        ]
        var second = Hunk(oldStart: 40, oldCount: 2, newStart: 41, newCount: 2, section: "")
        second.lines = [
            line(.context, "}", 40, 41),
            line(.removed, "// end", 41, nil),
            line(.added, "// end of Order", nil, 42),
        ]
        second.lines[2].noNewlineAtEnd = true
        var modified = FileDiff(
            oldPath: "Sources/Order.swift", newPath: "Sources/Order.swift", status: .modified)
        modified.hunks = [first, second]
        var deletedHunk = Hunk(oldStart: 1, oldCount: 2, newStart: 0, newCount: 0, section: "")
        deletedHunk.lines = [line(.removed, "legacy", 1, nil), line(.removed, "code", 2, nil)]
        var deleted = FileDiff(oldPath: "Legacy.txt", newPath: nil, status: .deleted)
        deleted.hunks = [deletedHunk]
        var binary = FileDiff(oldPath: "logo.png", newPath: "logo.png", status: .modified)
        binary.isBinary = true
        let renamed = FileDiff(
            oldPath: "Old.md", newPath: "New.md", status: .renamed(similarity: 100))
        return ReviewDiff(
            scope: .all,
            files: [
                ReviewFile(diff: modified), ReviewFile(diff: deleted), ReviewFile(diff: binary),
                ReviewFile(diff: renamed),
            ])
    }()

    private func view(
        _ mode: DiffLayoutMode, _ appearance: NSAppearance.Name, highContrast: Bool = false,
        collapsed: Set<String> = []
    ) -> DiffScrollView {
        let view = DiffScrollView()
        view.appearance = NSAppearance(named: appearance)
        view.increaseContrastOverride = highContrast
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 460)
        view.show(
            DiffContent(review: Self.review, mode: mode, collapsed: collapsed), position: .top)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test(arguments: [
        (DiffLayoutMode.unified, NSAppearance.Name.aqua, false, "unified-light"),
        (.unified, .darkAqua, false, "unified-dark"),
        (.unified, .aqua, true, "unified-light-high-contrast"),
        (.unified, .darkAqua, true, "unified-dark-high-contrast"),
        (.split, .aqua, false, "split-light"),
        (.split, .darkAqua, false, "split-dark"),
        (.split, .darkAqua, true, "split-dark-high-contrast"),
    ])
    func modesAndAppearances(
        mode: DiffLayoutMode, appearance: NSAppearance.Name, highContrast: Bool, name: String
    ) {
        assertSnapshot(
            of: view(mode, appearance, highContrast: highContrast), as: .image,
            named: "\(name)-\(Self.os)")
    }

    @Test func stickyHeaderPinsTheFileBeingRead() {
        let view = view(.unified, .aqua)
        view.moveHunk(by: 1)
        view.moveHunk(by: 1)
        assertSnapshot(of: view, as: .image, named: "sticky-\(Self.os)")
    }

    @Test func gapsBetweenHunksOfferExpansion() {
        var hunk = Hunk(oldStart: 10, oldCount: 3, newStart: 10, newCount: 3, section: "")
        hunk.lines = [
            Self.line(.context, "line 10", 10, 10),
            Self.line(.removed, "line 11", 11, nil),
            Self.line(.added, "line eleven", nil, 11),
            Self.line(.context, "line 12", 12, 12),
        ]
        var file = FileDiff(oldPath: "a.txt", newPath: "a.txt", status: .modified)
        file.hunks = [hunk]
        let lines = (1...30).map { $0 == 11 ? "line eleven" : "line \($0)" }
        let content = DiffContent(
            review: ReviewDiff(scope: .all, files: [ReviewFile(diff: file)]),
            contents: ["a.txt": FileContents(old: nil, new: lines.joined(separator: "\n") + "\n")],
            expansions: ["a.txt": [0: GapExpansion(bottom: 3)]])
        let view = DiffScrollView()
        view.appearance = NSAppearance(named: .aqua)
        view.increaseContrastOverride = false
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        view.show(content, position: .top)
        view.layoutSubtreeIfNeeded()
        assertSnapshot(of: view, as: .image, named: "gaps-\(Self.os)")
    }

    @Test func imagesPreviewSideBySideUnderTheirSizes() throws {
        func png(_ color: NSColor, _ size: NSSize) throws -> Data {
            let image = NSImage(size: size, flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init))
            return try #require(rep.representation(using: .png, properties: [:]))
        }
        var file = FileDiff(oldPath: "logo.png", newPath: "logo.png", status: .modified)
        file.isBinary = true
        let content = DiffContent(
            review: ReviewDiff(scope: .all, files: [ReviewFile(diff: file)]),
            contents: [
                "logo.png": FileContents(
                    oldSize: 1200, newSize: 2400,
                    oldImage: try png(.systemBlue, NSSize(width: 80, height: 40)),
                    newImage: try png(.systemOrange, NSSize(width: 40, height: 80)))
            ])
        let view = DiffScrollView()
        view.appearance = NSAppearance(named: .aqua)
        view.increaseContrastOverride = false
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 340)
        view.show(content, position: .top)
        view.layoutSubtreeIfNeeded()
        assertSnapshot(of: view, as: .image, named: "image-\(Self.os)")
    }

    @Test func collapsedFileShowsOnlyItsHeader() {
        let view = view(.unified, .aqua, collapsed: ["Sources/Order.swift"])
        assertSnapshot(of: view, as: .image, named: "collapsed-\(Self.os)")
    }
}
