import AppKit
import SeamCore
import SwiftUI
import TestSupport
import Testing

@testable import Features

/// Geometry of a worktree row (SPEC §7.2), measured from off-screen renders.
@MainActor
struct WorktreeRowLayoutTests {
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
}
