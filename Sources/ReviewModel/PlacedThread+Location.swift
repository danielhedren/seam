import Foundation
import SeamCore

extension PlacedThread {
    /// Where the thread is when that isn't on its lines in the diff; nil when it is.
    package var location: String? {
        switch placement {
        case .lines: nil
        case .outdated: String(localized: "outdated", bundle: .module)
        case .later: String(localized: "from a later commit", bundle: .module)
        case .notShown:
            thread.github?.onFile == true
                ? nil : String(localized: "not in this diff", bundle: .module)
        }
    }
}
