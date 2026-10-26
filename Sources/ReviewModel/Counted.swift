import Foundation

/// "1 commit" or "3 commits". Explicit forms: Foundation's automatic agreement takes "commit" for
/// a verb and gets it backwards.
package enum Counted {
    package static func commits(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 commit", bundle: .module)
            : String(localized: "\(count) commits", bundle: .module)
    }

    package static func comments(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 comment", bundle: .module)
            : String(localized: "\(count) comments", bundle: .module)
    }

    package static func openThreads(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 open thread", bundle: .module)
            : String(localized: "\(count) open threads", bundle: .module)
    }

    package static func matches(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 match", bundle: .module)
            : String(localized: "\(count) matches", bundle: .module)
    }

    package static func files(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 file", bundle: .module)
            : String(localized: "\(count) files", bundle: .module)
    }

    package static func uncommittedFiles(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 uncommitted file", bundle: .module)
            : String(localized: "\(count) uncommitted files", bundle: .module)
    }
}
