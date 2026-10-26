import SeamCore

/// What the commit list says while it has no commits (SPEC §7.2.1).
package enum CommitListStatus: Equatable {
    case detecting(showsProgress: Bool)
    case missingDirectory, failed
    case baseGone(String)

    /// A log loaded before the directory or the chosen base went is no longer true.
    package var keepsLog: Bool {
        switch self {
        case .detecting, .failed: true
        case .missingDirectory, .baseGone: false
        }
    }

    /// Nil once the commits are listed.
    @MainActor
    package static func of(_ review: WorktreeReview) -> CommitListStatus? {
        switch review.problem {
        case .missingDirectory: .missingDirectory
        case .overrideGone(let ref): .baseGone(ref)
        case .gitFailed: .failed
        case .editorFailed, .seenGone, nil:
            review.commitLog == nil && review.isLoading
                ? .detecting(showsProgress: review.showsProgress) : nil
        }
    }
}
