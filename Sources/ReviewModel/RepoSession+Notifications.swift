import Foundation
import GitKit
import Observation
import SeamCore

/// Notifications (SPEC §7.10): whenever what the session shows changes, the news since the last
/// look is logged in the bell, of the kinds Settings has on, and posted in the background or,
/// when asked, in front too.
extension RepoSession {
    func startNotifications() {
        lastSnapshot = notificationSnapshot()
        notesOpens = true
        watchForNews()
        watchBadge()
    }

    /// The Dock's badge follows its switch in Settings.
    private func watchBadge() {
        guard !isClosed else { return }
        let badges = withObservationTracking {
            settings.badgesDock
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchBadge() }
        }
        services.notifications.setBadgesDock(badges, on: services.platform)
    }

    /// The reader opened `subject` here: its news is read, and its notifications leave
    /// Notification Center, also those the log no longer has.
    func noteOpened(_ subject: NotificationSubject) {
        guard notesOpens else { return }
        let platform = services.platform
        services.notifications.noteOpened(subject, on: platform)
        Task {
            let ids = await platform.deliveredNotificationIDs().filter(subject.covers)
            if !ids.isEmpty { platform.removeNotifications(ids.sorted()) }
        }
    }

    /// A click on the bell's entry: what it's about opens, in whichever window has it.
    package func openNotification(_ entry: NotificationLog.Entry) {
        showsNotifications = false
        services.notifications.open(entry, on: services.platform)
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
        // The bell logs all of it; only the banner waits for the background.
        let posts = settings.notifiesInFront || !isAppActive
        for event in events where settings.notifications.contains(event.kind) {
            let notification: SeamNotification
            if let listed = NotificationText.listed(event, repo: directory.path) {
                notification = listed
            } else if let review = (reviews + pullRequestReviews).first(where: {
                $0.id == event.worktree
            }) {
                notification = NotificationText.notification(
                    event, in: review, repo: directory.path)
            } else {
                continue
            }
            services.notifications.record(notification, posted: posts, on: services.platform)
            if posts { services.platform.notify(notification) }
        }
    }

    /// What awaits the author per worktree now. A worktree's own threads count only once its
    /// reader is known, so the author's words aren't mistaken for an agent's.
    func notificationSnapshot() -> NotificationSnapshot {
        var worktrees: [String: NotificationSnapshot.Worktree] = [:]
        // A pull request review has no Seam threads, only GitHub's discussion (SPEC §7.10).
        for review in reviews + pullRequestReviews where !review.worktree.isMissing {
            // What was kept from before the session opened is a state, not news.
            let pullRequest = pullRequests?.hasRead == true ? review.pullRequest : nil
            var entry = NotificationSnapshot.Worktree(pullRequest: pullRequest)
            if review.isPullRequestReview {
                entry.threadsRead = true
            } else if let threads, threads.hasLoaded,
                let reader = threads.reader(knownIn: review.id)
            {
                entry.threadsRead = true
                for thread in threads.threads(in: review.id) where reader.awaitsReply(thread) {
                    entry.awaiting[thread.id] = thread.comments.last
                }
            } else {
                entry.threadsRead = false
                learnReader(in: review.id)
            }
            // A discussion counts once it was read for the PR the worktree has now.
            if let number = pullRequest?.number, let conversation = review.conversation,
                conversation.pullRequest == number,
                pullRequestThreads?.readThisSession(review.id) == number
            {
                let viewer = conversation.viewer
                entry.discussionRead = true
                entry.conversation = Dictionary(
                    conversation.items.filter { $0.author != viewer }.map { ($0.key, $0) },
                    uniquingKeysWith: { first, _ in first })
                for thread in pullRequestThreads?.threads(in: review.id) ?? []
                where thread.github?.pullRequest == number {
                    for comment in thread.comments where comment.author != viewer {
                        guard let id = comment.githubID else { continue }
                        entry.gitHubComments[id] = NotificationEvent.Comment(
                            author: comment.author, body: comment.body, thread: thread.id)
                    }
                }
            }
            worktrees[review.id] = entry
        }
        return NotificationSnapshot(worktrees: worktrees, listed: listedSnapshot)
    }

    private func learnReader(in worktree: String) {
        Task { [threads] in _ = await threads?.reader(in: worktree) }
    }
}

/// What a notification says (SPEC §7.10): the worktree's branch as the title, then what
/// happened.
@MainActor
enum NotificationText {
    /// A pull request review's news is titled with the PR and opens it again from `repo`.
    static func notification(_ event: NotificationEvent, in review: WorktreeReview, repo: String)
        -> SeamNotification
    {
        let reviewed = review.isPullRequestReview ? review.pullRequest : nil
        let title =
            reviewed.map { "#\($0.number) \($0.title)" }
            ?? review.worktree.branch ?? review.worktree.name
        var thread: String?
        let body: String
        let id: String
        switch event.what {
        case .agent(let threadID, let author, let text):
            thread = threadID
            id = "agent-\(threadID)"
            body = String(localized: "\(author): \(plain(text))", bundle: .module)
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
                plain(item.body).isEmpty
                ? String(
                    localized: "\(item.author) \(verdict) #\(String(pullRequest.number))",
                    bundle: .module)
                : String(
                    localized:
                        "\(item.author) \(verdict) #\(String(pullRequest.number)): \(plain(item.body))",
                    bundle: .module)
        case .comments(let pullRequest, let comments):
            thread = comments.first?.thread
            id = "comments-\(pullRequest.number)"
            body =
                if comments.count == 1, let first = comments.first {
                    String(
                        localized:
                            "\(first.author) on #\(String(pullRequest.number)): \(plain(first.body))",
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
        // Posted through `listed(_:repo:)`, not about a worktree.
        case .reviewRequested(let pullRequest), .newPullRequest(let pullRequest),
            .newCommits(let pullRequest):
            id = "pr-\(pullRequest.number)"
            body = pullRequest.title
        }
        let url =
            reviewed.map { SeamURL(path: repo, pullRequest: $0.number).url }
            ?? SeamURL(path: review.id, thread: thread).url
        return SeamNotification(
            id: "\(review.id)|\(id)", group: review.id, title: title, body: body, url: url)
    }

    /// News about a listed pull request: titled with it, and stacked per repo. Nil for news
    /// about a worktree.
    static func listed(_ event: NotificationEvent, repo: String) -> SeamNotification? {
        let pullRequest: PullRequest
        let body: String
        switch event.what {
        case .reviewRequested(let requested):
            pullRequest = requested
            body = String(
                localized: "\(requested.author) asks you to review", bundle: .module)
        case .newPullRequest(let opened):
            pullRequest = opened
            body = String(localized: "New pull request by \(opened.author)", bundle: .module)
        case .newCommits(let pushed):
            pullRequest = pushed
            body = String(localized: "New commits since you last viewed it", bundle: .module)
        default:
            return nil
        }
        let number = String(pullRequest.number)
        let suffix = if case .newCommits = event.what { "-commits" } else { "" }
        return SeamNotification(
            id: "\(repo)|pr-\(number)\(suffix)", group: repo,
            title: "#\(number) \(pullRequest.title)",
            body: body, url: SeamURL(path: repo, pullRequest: pullRequest.number).url)
    }

    /// A comment's Markdown as one line of plain text: a notification shows a line or two and
    /// draws no Markdown, and bots' comments open with HTML comments and headings.
    nonisolated static func plain(_ markdown: String) -> String {
        var text = markdown.replacing(/<!--[\s\S]*?-->/, with: "")
            .replacing(
                /<\/?(?i:details|summary|br|p|div|span|sub|sup|b|i|a|img)\b[^>]*>/, with: " ")
        text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.replacing(
                /^\s*(?:`{3,}.*|~{3,}.*|#{1,6}\s+|>\s?|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)/,
                with: "")
        }.joined(separator: " ")
        text = text.replacing(/!?\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
            .replacing(/\*\*|~~|`/, with: "")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
