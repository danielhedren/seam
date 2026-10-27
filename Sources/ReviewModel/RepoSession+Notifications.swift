import Foundation
import GitKit
import Observation
import SeamCore

/// Notifications (SPEC §7.10): whenever what the session shows changes, the news since the last
/// look is posted, of the kinds Settings has on, and only in the background unless asked.
extension RepoSession {
    func startNotifications() {
        lastSnapshot = notificationSnapshot()
        watchForNews()
    }

    private func watchForNews() {
        guard !isClosed else { return }
        let snapshot = withObservationTracking {
            notificationSnapshot()
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchForNews() }
        }
        let events = NotificationRules.events(from: lastSnapshot, to: snapshot)
        lastSnapshot = snapshot
        let settings = settings
        guard settings.notifiesInFront || !isAppActive else { return }
        for event in events where settings.notifications.contains(event.kind) {
            guard let review = reviews.first(where: { $0.id == event.worktree }) else { continue }
            services.platform.notify(NotificationText.notification(event, in: review))
        }
    }

    /// What awaits the author per worktree now. A worktree's own threads count only once its
    /// reader is known, so the author's words aren't mistaken for an agent's.
    func notificationSnapshot() -> NotificationSnapshot {
        var worktrees: [String: NotificationSnapshot.Worktree] = [:]
        for review in reviews where !review.worktree.isMissing {
            var entry = NotificationSnapshot.Worktree(pullRequest: review.pullRequest)
            if let threads, threads.hasLoaded, let reader = threads.reader(knownIn: review.id) {
                entry.threadsRead = true
                for thread in threads.threads(in: review.id) where reader.awaitsReply(thread) {
                    entry.awaiting[thread.id] = thread.comments.last
                }
            } else {
                entry.threadsRead = false
                learnReader(in: review.id)
            }
            if let conversation = review.conversation {
                let viewer = conversation.viewer
                entry.discussionRead = true
                entry.conversation = Dictionary(
                    conversation.items.filter { $0.author != viewer }.map { ($0.key, $0) },
                    uniquingKeysWith: { first, _ in first })
                for thread in pullRequestThreads?.threads(in: review.id) ?? [] {
                    for comment in thread.comments where comment.author != viewer {
                        guard let id = comment.githubID else { continue }
                        entry.gitHubComments[id] = NotificationEvent.Comment(
                            author: comment.author, body: comment.body, thread: thread.id)
                    }
                }
            }
            worktrees[review.id] = entry
        }
        return NotificationSnapshot(worktrees: worktrees)
    }

    private func learnReader(in worktree: String) {
        Task { [threads] in _ = await threads?.reader(in: worktree) }
    }
}

/// What a notification says (SPEC §7.10): the worktree's branch as the title, then what
/// happened.
@MainActor
enum NotificationText {
    static func notification(_ event: NotificationEvent, in review: WorktreeReview)
        -> SeamNotification
    {
        let title = review.worktree.branch ?? review.worktree.name
        var thread: String?
        let body: String
        let id: String
        switch event.what {
        case .agent(let threadID, let author, let text):
            thread = threadID
            id = "agent-\(threadID)"
            body = String(localized: "\(author): \(text)", bundle: .module)
        case .checksFailed(let pullRequest):
            id = "checks-\(pullRequest.number)-\(pullRequest.headCommit)"
            body = String(
                localized: "Checks failed on #\(String(pullRequest.number)) \(pullRequest.title)",
                bundle: .module)
        case .checksPassed(let pullRequest):
            id = "checks-\(pullRequest.number)-\(pullRequest.headCommit)"
            body = String(
                localized: "Checks passed on #\(String(pullRequest.number)) \(pullRequest.title)",
                bundle: .module)
        case .review(let pullRequest, let item):
            id = "review-\(item.key)"
            let verdict = PullRequestText.verdict(item.kind) ?? ""
            body =
                item.body.isEmpty
                ? String(
                    localized: "\(item.author) \(verdict) #\(String(pullRequest.number))",
                    bundle: .module)
                : String(
                    localized:
                        "\(item.author) \(verdict) #\(String(pullRequest.number)): \(item.body)",
                    bundle: .module)
        case .comments(let pullRequest, let comments):
            thread = comments.first?.thread
            id = "comments-\(pullRequest.number)"
            body =
                if comments.count == 1, let first = comments.first {
                    String(
                        localized:
                            "\(first.author) on #\(String(pullRequest.number)): \(first.body)",
                        bundle: .module)
                } else {
                    String(
                        localized:
                            "\(String(comments.count)) new comments on #\(String(pullRequest.number))",
                        bundle: .module)
                }
        case .readyToMerge(let pullRequest):
            id = "ready-\(pullRequest.number)"
            body = String(
                localized: "#\(String(pullRequest.number)) is ready to merge", bundle: .module)
        case .merged(let pullRequest):
            id = "closed-\(pullRequest.number)"
            body = String(localized: "#\(String(pullRequest.number)) merged", bundle: .module)
        case .closed(let pullRequest):
            id = "closed-\(pullRequest.number)"
            body = String(localized: "#\(String(pullRequest.number)) was closed", bundle: .module)
        }
        return SeamNotification(
            id: "\(review.id)|\(id)", group: review.id, title: title, body: body,
            url: SeamURL(path: review.id, thread: thread).url)
    }
}
