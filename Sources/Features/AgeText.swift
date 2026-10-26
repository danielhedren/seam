import ReviewModel
import SwiftUI

extension EnvironmentValues {
    /// The moment ages are measured from; fixed in window snapshots so they don't drift.
    @Entry var ageReference: Date?
}

/// "3 hr ago", kept current once a minute; "now" under a minute.
struct AgeText: View {
    let date: Date
    @Environment(\.ageReference) private var reference

    var body: some View {
        if let reference {
            Text(Self.age(of: date, at: reference))
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(Self.age(of: date, at: context.date))
            }
        }
    }

    static func age(of date: Date, at now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        // Ages refresh once a minute, so seconds would go stale; a modification time ahead of
        // this Mac's clock is also just now, not "in 9 mo".
        guard now.timeIntervalSince(date) >= 60 else {
            return String(localized: "now", bundle: .module)
        }
        return Date.AnchoredRelativeFormatStyle(
            anchor: date, presentation: .numeric, unitsStyle: .narrow, locale: locale
        )
        .format(now)
    }
}
