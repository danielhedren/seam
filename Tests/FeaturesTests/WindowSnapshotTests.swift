import AppKit
import GitKit
import ReviewTestSupport
import SeamCore
import SnapshotTesting
import SwiftUI
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

/// SPEC §10: images of the window's panes, rendered in this process with a fixture repo, so
/// layout and sizing are checked without driving the real screen. Sidebar rows are rendered
/// outside their List: AppKit draws a sidebar's selection with a layer effect that an off-screen
/// render shows as solid black. Record with `SNAPSHOT_TESTING_RECORD=all swift test`.
@MainActor
@Suite(
    .timeLimit(.minutes(1)),
    .snapshots(record: .missing),
    .enabled("the references are drawn on a 2x display") {
        await MainActor.run { retinaScreen() != nil || previewDirectory != nil }
    })
struct WindowSnapshotTests {
    private static let os =
        "macOS\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)-2x"
    /// The fixture's clock starts here (`HermeticGit`); ages are measured three hours later.
    private static let fixtureEpoch = Date(timeIntervalSince1970: 1_767_225_600)
    private static let now = fixtureEpoch.addingTimeInterval(3 * 3600)

    /// A main worktree level with its base, and a feature branch with two commits, an edit and
    /// an untracked file.
    private func session() async throws -> (RepoSession, FixtureRepo) {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit(
            "src/Order.cs", "class Order\n{\n    int Total() => 1;\n}\n", "Add the order",
            in: tree)
        try await repo.commit(
            "src/Order.cs",
            "class Order\n{\n    int Total() => 1;\n\n    int Count() => 0;\n}\n",
            "Count the lines", in: tree)
        try repo.write(
            "src/Order.cs", "class Order\n{\n    int Total() => 2;\n\n    int Count() => 0;\n}\n",
            in: tree)
        try repo.write("notes.md", "# Notes\n", in: tree)
        // Working-tree files count towards a row's age, so they get the fixture's clock too.
        for file in ["src/Order.cs", "notes.md"] {
            try FileManager.default.setAttributes(
                [.modificationDate: Self.fixtureEpoch.addingTimeInterval(3600)],
                ofItemAtPath: tree.appending(path: file).path)
        }
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        await session.settled()
        await session.selected?.highlighted()
        return (session, repo)
    }

    @Test func worktreeRows() async throws {
        let (session, _) = try await session()
        let rows = VStack(alignment: .leading, spacing: 8) {
            ForEach(session.sortedReviews) { WorktreeRow(review: $0) }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        for (appearance, name) in Self.appearances {
            check(
                of: try render(rows, size: CGSize(width: 260, height: 150), appearance),
                as: .image(precision: 0.99, perceptualPrecision: 0.98),
                named: "worktrees-\(name)-\(Self.os)")
        }
    }

    @Test func commitRows() async throws {
        let (session, _) = try await session()
        let review = try #require(session.selected)
        let log = try #require(review.commitLog)
        let rows = VStack(alignment: .leading, spacing: 10) {
            WorkingTreeRow(
                files: review.activity?.uncommittedFiles ?? 0,
                threads: FileThreadCounts(open: 1))
            // The newest commit carries both kinds of thread, the next only resolved ones.
            ForEach(Array(log.commits.enumerated()), id: \.element.id) { index, commit in
                CommitRow(
                    commit: commit,
                    threads: [
                        FileThreadCounts(open: 1, gitHubOpen: 2),
                        FileThreadCounts(resolved: 1, gitHubResolved: 1),
                    ].dropFirst(index).first)
            }
            BaseRow(commit: log.base, parent: review.parentName)
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        for (appearance, name) in Self.appearances {
            check(
                of: try render(rows, size: CGSize(width: 260, height: 230), appearance),
                as: .image(precision: 0.99, perceptualPrecision: 0.98),
                named: "commits-\(name)-\(Self.os)")
        }
    }

    @Test func filesAndDiff() async throws {
        let (session, _) = try await session()
        let review = try #require(session.selected)
        let panes = HStack(spacing: 0) {
            FileList(
                session: session, review: review, filterFocus: FocusState<Bool>().projectedValue
            )
            .frame(width: 280)
            Divider()
            DiffPane(session: session, review: review)
        }
        for (appearance, name) in Self.appearances {
            check(
                of: try render(panes, size: CGSize(width: 1000, height: 420), appearance),
                as: .image(precision: 0.99, perceptualPrecision: 0.98),
                named: "files-diff-\(name)-\(Self.os)")
        }
    }

    @Test func searchBesideTheDiff() async throws {
        let (session, _) = try await session()
        let review = try #require(session.selected)
        let clock = try #require(session.services.clock as? ManualClock)
        session.showSearch()
        review.search.text = "total"
        await clock.sleepers()
        clock.advance(by: WorktreeReview.filterDelay)
        await until { review.searchResult != nil }
        let panes = HStack(spacing: 0) {
            FileList(
                session: session, review: review, filterFocus: FocusState<Bool>().projectedValue
            )
            .frame(width: 280)
            Divider()
            DiffPane(session: session, review: review)
        }
        for (appearance, name) in Self.appearances {
            check(
                of: try render(panes, size: CGSize(width: 1000, height: 420), appearance),
                as: .image(precision: 0.99, perceptualPrecision: 0.98),
                named: "search-diff-\(name)-\(Self.os)")
        }
    }

    @Test func aNewThreadsCardInTheDiff() async throws {
        let (session, _) = try await session()
        let review = try #require(session.selected)
        session.draft = ThreadDraft(
            worktree: review.id,
            anchor: try #require(review.anchor(path: "src/Order.cs", side: .new, lines: 3...3)),
            body: "Why did the total change?")
        for (appearance, name) in Self.appearances {
            check(
                of: try render(
                    DiffPane(session: session, review: review),
                    size: CGSize(width: 700, height: 420), appearance),
                as: .image(precision: 0.99, perceptualPrecision: 0.98),
                named: "new-thread-\(name)-\(Self.os)")
        }
    }

    /// Threads in the file list's column beside the diff, with one open in the diff and one on
    /// a file the diff doesn't show, whose card goes above the first file.
    @Test func threadsBesideTheDiff() async throws {
        let (session, _) = try await session()
        let review = try #require(session.selected)
        let repository = try #require(session.repository)
        let anchor = try #require(review.anchor(path: "src/Order.cs", side: .new, lines: 3...3))
        var counter = 0
        let ids = {
            counter += 1
            return String(format: "%08x", counter)
        }
        try session.services.threads.update(repository) { threads throws(ThreadError) in
            let thread = try ThreadRules.open(
                &threads, worktree: review.id, anchor: anchor, author: "you",
                body: "Why did the total change to **2**?", now: Self.fixtureEpoch, newID: ids)
            try ThreadRules.reply(
                &threads, to: thread.id, author: "claude",
                body: "The order now counts its delivery line; see `Count()`.",
                now: Self.fixtureEpoch.addingTimeInterval(1800), newID: ids)
            _ = try ThreadRules.open(
                &threads, worktree: review.id,
                anchor: ThreadAnchor(
                    path: "notes.md", side: .new, lines: 1...1, text: ["# Notes"]),
                author: "claude", body: "Add a line on what changed.",
                now: Self.fixtureEpoch.addingTimeInterval(2400), newID: ids)
            _ = try ThreadRules.open(
                &threads, worktree: review.id,
                anchor: ThreadAnchor(
                    path: "README.md", side: .new, lines: 4...4, text: ["## Install"]),
                author: "you", body: "Say how to install it.",
                now: Self.fixtureEpoch.addingTimeInterval(2700), newID: ids)
        }
        await session.threads?.load()
        review.navigator = .threads
        session.selectedThreadID =
            review.placedThreads.first { $0.thread.anchor.path == "src/Order.cs" }?.id
        let panes = HStack(spacing: 0) {
            FileList(
                session: session, review: review, filterFocus: FocusState<Bool>().projectedValue
            )
            .frame(width: 300)
            Divider()
            DiffPane(session: session, review: review)
        }
        for (appearance, name) in Self.appearances {
            check(
                of: try render(panes, size: CGSize(width: 1100, height: 620), appearance),
                as: .image(precision: 0.99, perceptualPrecision: 0.98),
                named: "threads-\(name)-\(Self.os)")
        }
    }

    @Test func threadsAwaitingTheReader() async throws {
        let (session, _) = try await session()
        let review = try #require(session.selected)
        let repository = try #require(session.repository)
        let anchor = try #require(review.anchor(path: "src/Order.cs", side: .new, lines: 3...3))
        try session.services.threads.update(repository) { threads throws(ThreadError) in
            let thread = try ThreadRules.open(
                &threads, worktree: review.id, anchor: anchor, author: "you",
                body: "Why did the total change?", now: Self.fixtureEpoch, newID: { "0000000a" })
            try ThreadRules.reply(
                &threads, to: thread.id, author: "claude",
                body: "The order now counts its delivery line; see `Count()`.",
                now: Self.fixtureEpoch.addingTimeInterval(1800), newID: { "0000000b" })
        }
        await session.threads?.load()
        review.navigator = .threads
        let view = FileList(
            session: session, review: review, filterFocus: FocusState<Bool>().projectedValue
        )
        .frame(width: 300, height: 200, alignment: .top)
        for (appearance, name) in Self.appearances {
            check(
                of: try render(view, size: CGSize(width: 300, height: 200), appearance),
                as: .image(precision: 0.99, perceptualPrecision: 0.98),
                named: "awaiting-\(name)-\(Self.os)")
        }
    }

    @Test func fileRowsWithThreads() async throws {
        let (session, _) = try await session()
        let review = try #require(session.selected)
        let repository = try #require(session.repository)
        let anchor = try #require(review.anchor(path: "src/Order.cs", side: .new, lines: 3...3))
        try session.services.threads.update(repository) { threads throws(ThreadError) in
            _ = try ThreadRules.open(
                &threads, worktree: review.id, anchor: anchor, author: "you", body: "Why?",
                now: Self.fixtureEpoch)
            let resolved = try ThreadRules.open(
                &threads, worktree: review.id,
                anchor: ThreadAnchor(path: "notes.md", side: .new, lines: 1...1, text: ["# Notes"]),
                author: "claude", body: "Add a line.", now: Self.fixtureEpoch)
            try ThreadRules.setResolved(true, &threads, id: resolved.id, now: Self.fixtureEpoch)
        }
        await session.threads?.load()
        let list = FileList(
            session: session, review: review, filterFocus: FocusState<Bool>().projectedValue
        )
        .frame(width: 280)
        for (appearance, name) in Self.appearances {
            check(
                of: try render(list, size: CGSize(width: 280, height: 160), appearance),
                as: .image(precision: 0.99, perceptualPrecision: 0.98),
                named: "file-threads-\(name)-\(Self.os)")
        }
    }

    /// Every PR marker, a worktree row carrying one, and the file list's header showing it while
    /// the worktree list is hidden (SPEC §7.8).
    @Test func pullRequestMarkers() async throws {
        let (session, _) = try await session()
        let review = try #require(session.selected)
        func pullRequest(
            _ number: Int, _ state: PullRequest.State = .open, draft: Bool = false,
            review: PullRequest.Review = .none, failed: Int = 0, pending: Int = 0
        ) -> PullRequest {
            PullRequest(
                number: number, title: "Count the lines", url: "https://github.com/o/a/pull/1",
                state: state, isDraft: draft, head: "feature", headOwner: "o", headCommit: "abc",
                base: "main", review: review,
                checks: .init(passed: 2, failed: failed, pending: pending),
                updated: Self.fixtureEpoch)
        }
        var saved = SavedPullRequests()
        saved.byBranch["feature"] = pullRequest(12, review: .approved, failed: 1)
        let pullRequests = RepoPullRequests(
            services: session.services, directory: review.worktree.path, saved: saved,
            branches: { [] })
        review.pullRequests = pullRequests
        session.showsWorktreeList = false
        let markers: [PullRequest] = [
            pullRequest(1, draft: true), pullRequest(2), pullRequest(3, review: .commented),
            pullRequest(4, review: .changesRequested), pullRequest(5, review: .approved),
            pullRequest(6, .merged), pullRequest(7, .closed), pullRequest(8, failed: 1),
            pullRequest(9, pending: 1),
        ]
        let view = VStack(alignment: .leading, spacing: 10) {
            WorktreeRow(review: review)
            ForEach([markers.prefix(5), markers.dropFirst(5)], id: \.startIndex) { line in
                HStack(spacing: 10) {
                    ForEach(line, id: \.number) { PullRequestBadge(pullRequest: $0) }
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            FileList(
                session: session, review: review, filterFocus: FocusState<Bool>().projectedValue
            )
            .frame(width: 300, height: 40, alignment: .top)
        }
        .padding(12)
        .frame(width: 420, alignment: .leading)
        for (appearance, name) in Self.appearances {
            check(
                of: try render(view, size: CGSize(width: 420, height: 170), appearance),
                as: .image(precision: 0.99, perceptualPrecision: 0.98),
                named: "pull-requests-\(name)-\(Self.os)")
        }
    }

    @Test func aFinishedReviewSaysWhatThePullRequestSays() async throws {
        let (session, _) = try await session()
        let review = try #require(session.selected)
        var saved = SavedPullRequests()
        saved.byBranch["feature"] = PullRequest(
            number: 12, title: "Count the lines", url: "https://github.com/o/a/pull/12",
            state: .open, isDraft: false, head: "feature", headOwner: "o", headCommit: "abc",
            base: "main", review: .none, checks: .init(passed: 3, failed: 1),
            updated: Self.fixtureEpoch)
        saved.unpushed["feature"] = 2
        review.pullRequests = RepoPullRequests(
            services: session.services, directory: review.worktree.path, saved: saved,
            branches: { [] })
        for path in review.diff?.files.map(\.diff.path) ?? [] {
            session.toggleViewed(path, advance: false)
        }
        let view = FileList(
            session: session, review: review, filterFocus: FocusState<Bool>().projectedValue
        )
        .frame(width: 300, height: 140, alignment: .top)
        for (appearance, name) in Self.appearances {
            check(
                of: try render(view, size: CGSize(width: 300, height: 140), appearance),
                as: .image(precision: 0.99, perceptualPrecision: 0.98),
                named: "finished-\(name)-\(Self.os)")
        }
    }

    @Test func welcome() async throws {
        let repo = try await FixtureRepo()
        // Under the home folder, so the rows read the same "~/…" on any machine.
        let recent = ["seam", "website"].map {
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Code/\($0)")
        }
        let view = WelcomeView(services: services(repo.git), recent: recent) { _ in true }
        check(
            of: try render(view, size: CGSize(width: 900, height: 500), .aqua),
            as: .image(precision: 0.99, perceptualPrecision: 0.98),
            named: "welcome-\(Self.os)")
    }

    private static let appearances: [(NSAppearance.Name, String)] = [
        (.aqua, "light"), (.darkAqua, "dark"),
    ]

    /// Lays `view` out in an off-screen window and draws its layers, which unlike
    /// `cacheDisplay` includes SwiftUI's list rows.
    private func render(_ view: some View, size: CGSize, _ appearance: NSAppearance.Name) throws
        -> NSImage
    {
        let root =
            view
            .environment(OpenRequests(defaults: try scratchDefaults()))
            .environment(\.ageReference, Self.now)
        let host = NSHostingView(rootView: root)
        let screen = try #require(
            retinaScreen() ?? (previewDirectory == nil ? nil : NSScreen.main))
        let window = NSWindow(
            contentRect: NSRect(origin: screen.frame.origin, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        settle()
        let scale = 2
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            // An opaque base, as the window's own background would be.
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            host.layer?.render(in: context)
        }
        let image = try #require(context.makeImage())
        return NSImage(cgImage: image, size: size)
    }

    private func scratchDefaults() throws -> UserDefaults {
        Scratch.defaults("seam-snapshots")
    }
}

/// With `SEAM_PREVIEW_DIR` set, the images are written there at the main screen's scale instead
/// of compared: a way to look at the panes on a machine without a 2x screen.
private let previewDirectory = ProcessInfo.processInfo.environment["SEAM_PREVIEW_DIR"]
    .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

@MainActor
private func check(
    of image: @autoclosure () throws -> NSImage, as strategy: Snapshotting<NSImage, NSImage>,
    named name: String, fileID: StaticString = #fileID, file: StaticString = #filePath,
    testName: String = #function, line: UInt = #line, column: UInt = #column
) {
    guard let previewDirectory else {
        assertSnapshot(
            of: try image(), as: strategy, named: name, fileID: fileID, file: file,
            testName: testName, line: line, column: column)
        return
    }
    guard let image = try? image(), let tiff = image.tiffRepresentation,
        let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    else { return }
    try? FileManager.default.createDirectory(
        at: previewDirectory, withIntermediateDirectories: true)
    try? png.write(to: previewDirectory.appending(path: "\(name).png"))
}

/// A window draws at its screen's scale, so the references are drawn on a 2x screen (a Mac's
/// built-in one) whichever display is main: one set of references, not one per scale.
@MainActor
private func retinaScreen() -> NSScreen? {
    NSScreen.screens.first { $0.backingScaleFactor == 2 }
}

/// Lets SwiftUI and AppKit finish the layout and drawing they schedule on the run loop; a plain
/// function because `RunLoop.run` isn't available from async code.
@MainActor
private func settle() {
    runLoop(for: 0.4)
}
