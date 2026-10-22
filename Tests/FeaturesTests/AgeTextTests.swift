import Foundation
import Testing

@testable import Features

@MainActor
struct AgeTextTests {
    private let now = Date(timeIntervalSince1970: 1_767_225_600)

    @Test func pastDatesReadAsAnAge() {
        #expect(AgeText.age(of: now.addingTimeInterval(-3 * 3600), at: now) == "3 hr ago")
    }

    /// A file's modification time can be ahead of this Mac's clock (copied from another machine,
    /// restored from a backup); the row says it changed just now rather than "in 9 mo".
    @Test func futureDatesReadAsNow() {
        let future = now.addingTimeInterval(9 * 30 * 86400)
        #expect(AgeText.age(of: future, at: now) == "now")
    }

    @Test func underAMinuteReadsAsNow() {
        #expect(AgeText.age(of: now.addingTimeInterval(-30), at: now) == "now")
        #expect(AgeText.age(of: now.addingTimeInterval(-60), at: now) == "1 min ago")
    }
}
