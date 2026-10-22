import Foundation

/// "1 commit" or "3 commits". Explicit forms: Foundation's automatic agreement takes "commit" for
/// a verb and gets it backwards.
enum Counted {
    static func commits(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 commit", bundle: .module)
            : String(localized: "\(count) commits", bundle: .module)
    }

    static func comments(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 comment", bundle: .module)
            : String(localized: "\(count) comments", bundle: .module)
    }

    static func files(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 file", bundle: .module)
            : String(localized: "\(count) files", bundle: .module)
    }
}
