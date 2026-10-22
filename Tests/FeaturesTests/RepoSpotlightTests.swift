import CoreSpotlight
import Foundation
import Synchronization
import TestSupport
import Testing

@testable import Features

/// Remembers what it was asked to index.
private final class RecordingIndex: RepoIndex {
    let replaced = Mutex<[[URL]]>([])

    func replace(with repositories: [URL]) async {
        replaced.withLock { $0.append(repositories) }
    }
}

@MainActor @Suite struct RepoSpotlightTests {
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

    @Test func aSpotlightPickOpensItsPathAndOtherActivitiesNothing() {
        let pick = NSUserActivity(activityType: CSSearchableItemActionType)
        pick.userInfo = [CSSearchableItemActivityIdentifier: "/Users/me/Code/shop"]
        #expect(SpotlightRepoIndex.path(from: pick) == "/Users/me/Code/shop")
        let other = NSUserActivity(activityType: "com.example.other")
        other.userInfo = [CSSearchableItemActivityIdentifier: "/x"]
        #expect(SpotlightRepoIndex.path(from: other) == nil)
    }
}
