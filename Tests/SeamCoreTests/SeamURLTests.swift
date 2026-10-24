import Foundation
import SeamCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct SeamURLTests {
    @Test func urlsRoundTripPathsAndBases() throws {
        // What the seam command builds, the app must read back, whatever the path holds.
        let request = SeamURL(path: "/Users/me/my repo/a&b=c#d+ü", base: "origin/feat/ü x")
        let url = try #require(request.url)
        #expect(SeamURL(url) == request)
        #expect(SeamURL(try #require(URL(string: "seam://open?path=/r"))) == SeamURL(path: "/r"))
        #expect(SeamURL(try #require(URL(string: "seam://other?path=/r"))) == nil)
        #expect(SeamURL(try #require(URL(string: "seam://open"))) == nil)
    }
}
