import Foundation
import ReviewTestSupport
import Testing

@testable import Features
@testable import ReviewModel

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgeTextTests {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    /// The narrow style differs between locales ("1m ago" in en_US, "1 min ago" in en_SE).
    private func age(_ seconds: TimeInterval) -> String {
        AgeText.age(
            of: now.addingTimeInterval(seconds), at: now, locale: Locale(identifier: "en_US"))
    }

    @Test func pastDatesReadAsAnAge() {
        #expect(age(-3 * 3600) == "3h ago")
    }

    /// A file's modification time can be ahead of this Mac's clock (copied from another machine,
    /// restored from a backup); the row says it changed just now rather than "in 9 mo".
    @Test func futureDatesReadAsNow() {
        #expect(age(9 * 30 * 86400) == "now")
    }

    @Test func underAMinuteReadsAsNow() {
        #expect(age(-30) == "now")
        #expect(age(-60) == "1m ago")
    }
}
