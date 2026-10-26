import AppKit
import GitKit
import ReviewModel
import SeamCore
import SwiftUI

/// A worktree's pull request in GitHub's own design language (SPEC §7.8): its state's octicon
/// and colour, the number, then GitHub's check icon and the review.
/// Every state has its own shape, so the colour is never the only sign.
struct PullRequestBadge: View {
    let pullRequest: PullRequest
    var unpushed: Int?
    var read: Date?
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 3) {
            icon(Self.stateIcon(pullRequest.marker), Self.stateColor(pullRequest.marker))
            Text(verbatim: "#\(pullRequest.number)")
            if let ci = Self.ciIcon(pullRequest) {
                icon(ci.icon, ci.color)
            }
            if let review = Self.reviewIcon(pullRequest) {
                icon(review.icon, review.color)
            }
            // GitHub's reviewers see other code than the reader does, so it's said, not hovered.
            if let unpushed, unpushed > 0 { Text(verbatim: "↑\(unpushed)") }
        }
        .fixedSize()
        .help(PullRequestText.help(pullRequest, unpushed: unpushed, read: read))
    }

    /// Colours are unreadable on a selected row's accent fill; the shapes still tell them apart.
    private func icon(_ icon: Octicon, _ color: Color) -> some View {
        icon.image.resizable().frame(width: 12, height: 12)
            .foregroundStyle(
                prominence == .increased ? AnyShapeStyle(.foreground) : AnyShapeStyle(color))
    }

    static func stateIcon(_ marker: PullRequest.Marker) -> Octicon {
        switch marker {
        case .draft: .draft
        case .waitingForReview, .reviewed, .approved: .open
        case .merged: .merged
        case .closed: .closed
        }
    }

    static func stateColor(_ marker: PullRequest.Marker) -> Color {
        switch marker {
        case .draft: Primer.muted
        case .waitingForReview, .reviewed, .approved: Primer.open
        case .merged: Primer.done
        case .closed: Primer.danger
        }
    }

    static func ciIcon(_ pullRequest: PullRequest) -> (icon: Octicon, color: Color)? {
        switch pullRequest.ci {
        case .passed: (.check, Primer.open)
        case .running: (.dot, Primer.attention)
        case .failed: (.x, Primer.danger)
        case nil: nil
        }
    }

    /// GitHub's reviewer-list icons, with approval circled so it isn't read as passing checks;
    /// an open PR nobody has reviewed shows none.
    static func reviewIcon(_ pullRequest: PullRequest) -> (icon: Octicon, color: Color)? {
        switch pullRequest.marker {
        case .approved: (.approved, Primer.open)
        case .reviewed:
            pullRequest.review == .changesRequested
                ? (.changesRequested, Primer.danger) : (.comment, Primer.muted)
        case .draft, .waitingForReview, .merged, .closed: nil
        }
    }
}

/// The octicons in Resources/Octicons, drawn as templates so they take the badge's colours.
enum Octicon: String, CaseIterable {
    case open = "git-pull-request"
    case draft = "git-pull-request-draft"
    case merged = "git-merge"
    case closed = "git-pull-request-closed"
    case check
    case dot = "dot-fill"
    case x
    case approved = "check-circle-fill"
    case changesRequested = "file-diff"
    case comment
    case mark = "mark-github"

    @MainActor private static var images: [Octicon: NSImage] = [:]

    @MainActor var image: Image {
        nsImage.map { Image(nsImage: $0) } ?? Image(systemName: "questionmark.circle")
    }

    @MainActor var nsImage: NSImage? {
        if let image = Self.images[self] { return image }
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: "svg"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        Self.images[self] = image
        return image
    }
}

/// Primer's functional colours, light and dark, as github.com draws PR states.
enum Primer {
    static let open = color(light: 0x1A7F37, dark: 0x3FB950)
    static let done = color(light: 0x8250DF, dark: 0xAB7DF8)
    static let attention = color(light: 0x9A6700, dark: 0xD29922)
    static let danger = color(light: 0xD1242F, dark: 0xF85149)
    static let muted = color(light: 0x59636E, dark: 0x9198A1)

    private static func color(light: Int, dark: Int) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let hex =
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            })
    }
}
