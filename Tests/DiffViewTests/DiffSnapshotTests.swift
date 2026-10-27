import AppKit
import GitKit
import SeamCore
import SnapshotTesting
import Testing

@testable import DiffModel
@testable import DiffView

/// SPEC §10: image snapshots of the diff view, drawn at 2x in sRGB whatever the display.
/// Rendering differs between macOS releases, so each major version keeps its own references. Record with `SNAPSHOT_TESTING_RECORD=all swift test`.
@MainActor
@Suite(.timeLimit(.minutes(1)), .snapshots(record: .missing))
struct DiffSnapshotTests {
    private static let os = "macOS\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"

    private static func line(_ kind: DiffLine.Kind, _ text: String, _ old: Int?, _ new: Int?)
        -> DiffLine
    {
        DiffLine(kind: kind, text: text, oldNumber: old, newNumber: new)
    }

    /// `Order` ends before the second hunk, so it shows a header with no name.
    private static let syntax = [
        "Sources/Order.swift": FileSyntax(
            oldScopes: [SyntaxScope(lines: 0...39, name: "Order")],
            newScopes: [SyntaxScope(lines: 0...40, name: "Order")])
    ]

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
        collapsed: Set<String> = [], viewed: [String: ViewedMarks.Status] = [:],
        sinceViewed: Set<String> = []
    ) -> DiffScrollView {
        let view = DiffScrollView.forSnapshot()
        view.appearance = NSAppearance(named: appearance)
        view.increaseContrastOverride = highContrast
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 460)
        view.show(
            DiffContent(
                review: Self.review, mode: mode, collapsed: collapsed, syntax: Self.syntax,
                viewed: viewed, sinceViewed: sinceViewed),
            position: .top)
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
            of: view(mode, appearance, highContrast: highContrast), as: .image2x,
            named: "\(name)-\(Self.os)")
    }

    @Test func stickyHeaderPinsTheFileBeingRead() {
        let view = view(.unified, .aqua)
        view.moveHunk(by: 1)
        view.moveHunk(by: 1)
        assertSnapshot(of: view, as: .image2x, named: "sticky-\(Self.os)")
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
        let view = DiffScrollView.forSnapshot()
        view.appearance = NSAppearance(named: .aqua)
        view.increaseContrastOverride = false
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        view.show(content, position: .top)
        view.layoutSubtreeIfNeeded()
        assertSnapshot(of: view, as: .image2x, named: "gaps-\(Self.os)")
    }

    private static func png(_ size: NSSize, draw: @escaping (NSRect) -> Void) throws -> Data {
        // A bitmap of its own, sRGB at one pixel per point: an NSImage's would follow the screen,
        // as system colours do, so the fills are fixed sRGB values too.
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )?.retagging(with: .sRGB))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.current?.flushGraphics()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func imageView(
        _ status: FileStatus, old: Data?, new: Data?, _ appearance: NSAppearance.Name
    ) -> DiffScrollView {
        var file = FileDiff(oldPath: "logo.png", newPath: "logo.png", status: status)
        file.isBinary = true
        let content = DiffContent(
            review: ReviewDiff(scope: .all, files: [ReviewFile(diff: file)]),
            contents: [
                "logo.png": FileContents(
                    oldSize: old.map { _ in 1200 }, newSize: new.map { _ in 2400 },
                    oldImage: old, newImage: new)
            ])
        let view = DiffScrollView.forSnapshot()
        view.appearance = NSAppearance(named: appearance)
        view.increaseContrastOverride = false
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 340)
        view.show(content, position: .top)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func imagesPreviewSideBySideUnderTheirSizes() throws {
        func png(_ color: NSColor, _ size: NSSize) throws -> Data {
            try Self.png(size) { rect in
                color.setFill()
                rect.fill()
            }
        }
        let view = imageView(
            .modified,
            old: try png(
                NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1), NSSize(width: 80, height: 40)),
            new: try png(
                NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1), NSSize(width: 40, height: 80)),
            .aqua)
        assertSnapshot(of: view, as: .image2x, named: "image-\(Self.os)")
    }

    @Test func transparentImagesShowTheCheckerboardBehindThem() throws {
        let ring = try Self.png(NSSize(width: 120, height: 90)) { rect in
            NSColor(srgbRed: 1, green: 0.18, blue: 0.33, alpha: 1).setStroke()
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 10, dy: 10))
            path.lineWidth = 12
            path.stroke()
        }
        assertSnapshot(
            of: imageView(.added, old: nil, new: ring, .darkAqua), as: .image2x,
            named: "image-transparent-dark-\(Self.os)")
    }

    @Test func wrappedLinesContinueOnTheirOwnRows() {
        let view = DiffScrollView.forSnapshot()
        view.appearance = NSAppearance(named: .aqua)
        view.increaseContrastOverride = false
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
        view.show(
            DiffContent(review: Self.review, syntax: Self.syntax, wraps: true), position: .top)
        view.layoutSubtreeIfNeeded()
        assertSnapshot(of: view, as: .image2x, named: "wrapped-\(Self.os)")
    }

    @Test func viewedCheckboxesShowEachState() {
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let view = view(
                .unified, appearance, collapsed: ["Sources/Order.swift", "Legacy.txt"],
                viewed: ["Sources/Order.swift": .viewed, "Legacy.txt": .changedSinceViewed])
            assertSnapshot(of: view, as: .image2x, named: "viewed-\(name)-\(Self.os)")
        }
    }

    @Test func aFileShownSinceViewedSaysSoInItsHeader() {
        let view = view(
            .unified, .aqua, collapsed: ["Legacy.txt"],
            viewed: ["Sources/Order.swift": .changedSinceViewed, "Legacy.txt": .viewed],
            sinceViewed: ["Sources/Order.swift"])
        assertSnapshot(of: view, as: .image2x, named: "since-viewed-\(Self.os)")
    }

    /// An open thread's lines carry a solid bar; a hidden resolved one's, a hollow one.
    @Test func hiddenResolvedThreadsMarkTheirLinesHollow() {
        func marker(_ id: String, _ lines: ClosedRange<Int>, resolved: Bool) -> ThreadMarker {
            ThreadMarker(
                id: id, side: .new, lines: lines, latestAuthor: "you", latest: "Why?",
                commentCount: 1, isResolved: resolved,
                title: "Thread on line \(lines.lowerBound) · 1 comment")
        }
        let view = DiffScrollView.forSnapshot()
        view.appearance = NSAppearance(named: .aqua)
        view.increaseContrastOverride = false
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        var content = DiffContent(
            review: Self.review, collapsed: ["Legacy.txt"], syntax: Self.syntax,
            threads: ["Sources/Order.swift": [marker("open", 11...11, resolved: false)]])
        content.resolvedMarks = ["Sources/Order.swift": [marker("done", 9...10, resolved: true)]]
        view.show(content, position: .top)
        view.layoutSubtreeIfNeeded()
        assertSnapshot(of: view, as: .image2x, named: "resolved-marks-\(Self.os)")
    }

    @Test func sideBySideAThreadsRowSpansBothColumns() {
        let view = DiffScrollView.forSnapshot()
        view.appearance = NSAppearance(named: .aqua)
        view.increaseContrastOverride = false
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 260)
        let marker = ThreadMarker(
            id: "t", side: .old, lines: 9...9, latestAuthor: "claude",
            latest:
                "The total was an Int because the old API sent whole kronor; Decimal keeps öre.",
            commentCount: 2, isResolved: false,
            title: "Thread on old line 9 · 2 comments")
        view.show(
            DiffContent(
                review: Self.review, mode: .split, collapsed: ["Legacy.txt"], syntax: Self.syntax,
                threads: ["Sources/Order.swift": [marker]]),
            position: .top)
        view.layoutSubtreeIfNeeded()
        assertSnapshot(of: view, as: .image2x, named: "split-thread-\(Self.os)")
    }

    /// A closed GitHub thread's title carries GitHub's mark, as the open card's does.
    @Test func aClosedGitHubThreadCarriesGitHubsMark() throws {
        let view = DiffScrollView.forSnapshot()
        view.appearance = NSAppearance(named: .aqua)
        view.increaseContrastOverride = false
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        let svg = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/Features/Resources/Octicons/mark-github.svg")
        let mark = try #require(NSImage(contentsOf: svg))
        mark.isTemplate = true
        view.gitHubMark = mark
        let marker = ThreadMarker(
            id: "g", side: .new, lines: 9...9, latestAuthor: "octocat",
            latest: "Should this be a Decimal?", commentCount: 1, isResolved: false,
            source: .gitHub, title: "GitHub thread on line 9 · #12 · 1 comment")
        view.show(
            DiffContent(
                review: Self.review, collapsed: ["Legacy.txt"], syntax: Self.syntax,
                threads: ["Sources/Order.swift": [marker]]),
            position: .top)
        view.layoutSubtreeIfNeeded()
        assertSnapshot(of: view, as: .image2x, named: "github-thread-\(Self.os)")
    }

    @Test func collapsedFileShowsOnlyItsHeader() {
        let view = view(.unified, .aqua, collapsed: ["Sources/Order.swift"])
        assertSnapshot(of: view, as: .image2x, named: "collapsed-\(Self.os)")
    }
}

extension DiffScrollView {
    /// While a mouse is connected the system switches to legacy scrollers, which narrow the
    /// document, so references are drawn with overlay scrollers whatever is plugged in.
    fileprivate static func forSnapshot() -> DiffScrollView {
        let view = DiffScrollView()
        view.scrollerStyle = .overlay
        return view
    }
}

extension Snapshotting where Value == NSView, Format == NSImage {
    /// The view drawn at 2x whatever the main screen's scale, so references don't depend on the
    /// display the tests run on.
    @MainActor static var image2x: Snapshotting {
        Snapshotting<NSImage, NSImage>.image.pullback { view in
            let size = view.bounds.size
            // sRGB rather than the screen's profile, so every Mac draws the same pixels.
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2,
                    pixelsHigh: Int(size.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                    bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB)
            else { return NSImage() }
            rep.size = size
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: size)
            image.addRepresentation(rep)
            return image
        }
    }
}
