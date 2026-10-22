import SwiftUI

extension EnvironmentValues {
    /// The moment ages are measured from; fixed in window snapshots so they don't drift.
    @Entry var ageReference: Date?
}

/// "3 hr ago", kept current once a minute.
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

    static func age(of date: Date, at now: Date) -> String {
        Date.AnchoredRelativeFormatStyle(anchor: date, presentation: .numeric, unitsStyle: .narrow)
            .format(now)
    }
}
