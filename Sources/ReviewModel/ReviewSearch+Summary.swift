import Foundation
import SeamCore

extension ReviewSearch.Result {
    /// "23 matches in 5 files". A path counts once, however often the query is in it.
    package var summary: String {
        guard !files.isEmpty else { return String(localized: "No results", bundle: .module) }
        if isTruncated {
            return String(
                localized: "First \(ReviewSearch.limit.formatted()) matches", bundle: .module)
        }
        let matches = matchCount + files.count { !$0.pathRanges.isEmpty }
        return String(
            localized: "\(Counted.matches(matches)) in \(Counted.files(files.count))",
            bundle: .module)
    }
}
