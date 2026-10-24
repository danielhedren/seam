import AppKit
import SeamCore
import SwiftUI
import TestSupport
import Testing

@testable import Features

/// A worktree row (SPEC §7.2), measured from off-screen renders.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WorktreeRowTests {
    @Test func rowWithNothingToCountHasNoEmptyLine() async throws {
        let repo = try await FixtureRepo()
        let level = review(Worktree(path: repo.main, branch: "main", isMain: true), repo)
        let detached = review(
            Worktree(path: repo.main.appending(path: "../wt-spike"), isDetached: true), repo)
        // Name and branch against name and marker: two lines each.
        #expect(height(of: WorktreeRow(review: level)) == height(of: WorktreeRow(review: detached)))
    }

    @Test func markersStartAtTheRowsLeadingEdge() async throws {
        let repo = try await FixtureRepo()
        let detached = review(
            Worktree(path: repo.main.appending(path: "../wt-spike"), isDetached: true), repo)
        let image = try render(WorktreeRow(review: detached).padding(10))
        let mid = image.height / 2
        let name = try #require(leadingInk(in: image, rows: 0..<mid))
        let marker = try #require(leadingInk(in: image, rows: mid..<image.height))
        #expect(abs(name - marker) <= 2)
    }

    @Test func selectedRowDrawsCountsInItsTextColour() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("a.txt", "a\nb\n", "Add a", in: tree)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        await session.settled()
        let review = try #require(session.selected)
        #expect(review.activity?.changes?.additions == 2)
        let normal = try render(WorktreeRow(review: review))
        let selected = try render(
            WorktreeRow(review: review).environment(\.backgroundProminence, .increased))
        #expect(colouredPixels(in: normal) > 0)
        #expect(colouredPixels(in: selected) == 0)
    }

    private func review(_ worktree: Worktree, _ repo: FixtureRepo) -> WorktreeReview {
        WorktreeReview(worktree: worktree, services: services(repo.git))
    }

    private func height(of view: some View) -> CGFloat {
        NSHostingView(rootView: view.frame(width: 240)).fittingSize.height
    }

    private func render(_ view: some View) throws -> CGImage {
        let host = NSHostingView(rootView: view.frame(width: 240))
        host.frame.size = host.fittingSize
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    /// Pixels with a clearly green or red cast, as the `+`/`−` totals are drawn.
    private func colouredPixels(in image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return 0
        }
        let step = image.bitsPerPixel / 8
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let pixel = y * image.bytesPerRow + x * step
                let (r, g, b) = (Int(bytes[pixel]), Int(bytes[pixel + 1]), Int(bytes[pixel + 2]))
                if abs(g - r) > 60 && abs(g - b) > 40 { count += 1 }
            }
        }
        return count
    }

    /// The leftmost column in `rows` with a pixel that isn't transparent.
    private func leadingInk(in image: CGImage, rows: Range<Int>) -> Int? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return nil
        }
        let step = image.bitsPerPixel / 8
        for x in 0..<image.width {
            for y in rows where bytes[y * image.bytesPerRow + x * step + 3] > 40 { return x }
        }
        return nil
    }

    @Test func theUncommittedMarkSaysWhatItCounts() {
        #expect(Counted.uncommittedFiles(1) == "1 uncommitted file")
        #expect(Counted.uncommittedFiles(2) == "2 uncommitted files")
    }
}
