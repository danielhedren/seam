import AppKit
import CoreSpotlight
import Foundation
import SeamCore
import Synchronization
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

/// Remembers what it was asked to index.
private final class RecordingIndex: RepoIndex {
    let replaced = Mutex<[[URL]]>([])

    func replace(with repositories: [URL]) async {
        replaced.withLock { $0.append(repositories) }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct RepoSpotlightTests {
    @Test func openingARepoPutsTheRecentReposInSpotlight() async throws {
        let repo = try await FixtureRepo()
        let index = RecordingIndex()
        var services = services(repo.git)
        services.spotlight = index
        let session = RepoSession(directory: repo.main, services: services)

        await session.open()
        await session.spotlightTask?.value

        #expect(index.replaced.withLock { $0 } == [[repo.main]])
    }

    @Test func eachRepoIsAFolderNamedAfterItAndIdentifiedByItsPath() throws {
        let url = URL(fileURLWithPath: "/Users/me/Code/shop", isDirectory: true)
        let item = try #require(SpotlightRepoIndex.items(for: [url]).first)
        #expect(item.uniqueIdentifier == "/Users/me/Code/shop")
        #expect(item.domainIdentifier == SpotlightRepoIndex.domain)
        #expect(item.attributeSet.title == "shop")
        #expect(item.attributeSet.contentType == "public.folder")
    }

    @Test func theDelegateOpensThePickedRepoAsTheCommandWould() throws {
        let delegate = SeamAppDelegate()
        var sent: [URL] = []
        delegate.send = { sent.append($0) }
        let pick = NSUserActivity(activityType: CSSearchableItemActionType)
        pick.userInfo = [CSSearchableItemActivityIdentifier: "/Users/me/Code/second"]

        #expect(delegate.application(NSApplication.shared, continue: pick) { _ in })
        #expect(sent.map { SeamURL($0) } == [SeamURL(path: "/Users/me/Code/second")])
        let other = NSUserActivity(activityType: "com.example.other")
        #expect(!delegate.application(NSApplication.shared, continue: other) { _ in })
        #expect(sent.count == 1)
    }

    @Test func aSpotlightPickOpensItsPathAndOtherActivitiesNothing() {
        let pick = NSUserActivity(activityType: CSSearchableItemActionType)
        pick.userInfo = [CSSearchableItemActivityIdentifier: "/Users/me/Code/shop"]
        #expect(SpotlightRepoIndex.path(from: pick) == "/Users/me/Code/shop")
        let other = NSUserActivity(activityType: "com.example.other")
        other.userInfo = [CSSearchableItemActivityIdentifier: "/x"]
        #expect(SpotlightRepoIndex.path(from: other) == nil)
    }
}
