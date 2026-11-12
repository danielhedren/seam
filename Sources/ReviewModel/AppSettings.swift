import DiffModel
import Foundation
import Observation
import SeamCore

/// The settings of SPEC §12, kept in `UserDefaults`. Every load reads them, so a change applies
/// to the next reload of each worktree.
@MainActor
@Observable
public final class AppSettings {
    /// Empty means automatic: `origin/HEAD`, then `origin/main`, then `main`.
    package var defaultBase: String { didSet { save(defaultBase, "defaultBase") } }
    package var ignoredRefs: [String] { didSet { save(ignoredRefs, "ignoredRefs") } }
    package var generatedGlobs: [String] { didSet { save(generatedGlobs, "generatedGlobs") } }
    package var editorTemplate: String { didSet { save(editorTemplate, "editorTemplate") } }
    package var fontName: String { didSet { save(fontName, "fontName") } }
    package var fontSize: Double { didSet { save(fontSize, "fontSize") } }
    package var tabWidth: Int { didSet { save(tabWidth, "tabWidth") } }
    /// Side by side or unified, for every worktree; `s` flips it.
    package var layoutMode: DiffLayoutMode { didSet { save(layoutMode.rawValue, "defaultMode") } }
    package var whitespace: WhitespaceMode { didSet { save(whitespace.rawValue, "whitespace") } }
    package var contextLines: Int { didSet { save(contextLines, "contextLines") } }
    package var collapsesViewed: Bool { didSet { save(collapsesViewed, "collapsesViewed") } }
    /// Review › Show Resolved Threads: resolved threads keep their row in the diff.
    package var showsResolvedThreads: Bool {
        didSet { save(showsResolvedThreads, "showsResolvedThreads") }
    }

    /// View › Show Carriage Returns: a CRLF line's CR drawn as ␍; off, CRLF and LF look alike.
    package var showsCarriageReturns: Bool {
        didSet { save(showsCarriageReturns, "showsCarriageReturns") }
    }

    /// Pull request markers through gh (SPEC §7.8), on wherever gh is installed.
    package var showsPullRequests: Bool { didSet { save(showsPullRequests, "showsPullRequests") } }
    /// View › Show Pull Requests: other people's open PRs under the worktrees (SPEC §7.2.2).
    package var showsPullRequestList: Bool {
        didSet { save(showsPullRequestList, "showsPullRequestList") }
    }

    /// What notifications are about (SPEC §7.10); every kind is on until turned off. Saved as
    /// the kinds turned off, so a kind added later starts on.
    package var notifications: Set<NotificationKind> {
        didSet {
            let off = Set(NotificationKind.allCases).subtracting(notifications)
            save(off.map(\.rawValue).sorted(), "notificationsOff")
        }
    }
    /// Off, notifications wait until Seam isn't the app in front.
    package var notifiesInFront: Bool { didSet { save(notifiesInFront, "notifiesInFront") } }
    /// The Dock icon shows how many of the bell's entries are unread.
    package var badgesDock: Bool { didSet { save(badgesDock, "badgesDock") } }

    private let defaults: UserDefaults

    /// `locateApp` finds an installed app by bundle id, so the editor setting starts at one the
    /// reader has.
    public init(
        defaults: UserDefaults = .standard, locateApp: (String) -> URL? = { _ in nil }
    ) {
        self.defaults = defaults
        func value<Value>(_ key: String, _ fallback: Value) -> Value {
            defaults.object(forKey: "seam." + key) as? Value ?? fallback
        }
        defaultBase = value("defaultBase", "")
        ignoredRefs = value("ignoredRefs", DetectionSettings().ignoredRefs.map(\.pattern))
        generatedGlobs = value("generatedGlobs", DiffOptions.defaultGeneratedGlobs.map(\.pattern))
        editorTemplate = value(
            "editorTemplate", EditorCommand.installedDefault(locate: locateApp))
        fontName = value("fontName", "")
        fontSize = value("fontSize", 12)
        tabWidth = value("tabWidth", 4)
        layoutMode = DiffLayoutMode(rawValue: value("defaultMode", "")) ?? .unified
        whitespace = WhitespaceMode(rawValue: value("whitespace", "")) ?? .show
        contextLines = value("contextLines", 3)
        collapsesViewed = value("collapsesViewed", true)
        showsResolvedThreads = value("showsResolvedThreads", false)
        showsPullRequests = value("showsPullRequests", true)
        showsPullRequestList = value("showsPullRequestList", true)
        showsCarriageReturns = value("showsCarriageReturns", false)
        // Up to 0.4 `notifications` saved the kinds on, and only these six existed.
        let firstKinds: [NotificationKind] = [
            .agent, .checks, .review, .comment, .readyToMerge, .closed,
        ]
        let wereOn = (value("notifications", [String]()) as [String])
            .compactMap(NotificationKind.init)
        let wasSaved = defaults.object(forKey: "seam.notifications") != nil
        let off = value(
            "notificationsOff",
            wasSaved ? firstKinds.filter { !wereOn.contains($0) }.map(\.rawValue) : [])
        notifications = Set(NotificationKind.allCases)
            .subtracting(off.compactMap(NotificationKind.init))
        notifiesInFront = value("notifiesInFront", false)
        badgesDock = value("badgesDock", true)
    }

    private func save(_ value: some Any, _ key: String) {
        defaults.set(value, forKey: "seam." + key)
    }

    package var detection: DetectionSettings {
        DetectionSettings(
            defaultBase: defaultBase.isEmpty ? nil : defaultBase,
            ignoredRefs: ignoredRefs.map(Glob.init))
    }

    var diffOptions: DiffOptions {
        DiffOptions(
            contextLines: contextLines, whitespace: whitespace,
            generatedGlobs: generatedGlobs.map(Glob.init))
    }

    package var editor: EditorCommand { EditorCommand(template: editorTemplate) }

    package func adjustFontSize(by delta: Double) {
        fontSize = min(max(fontSize + delta, 8), 32)
    }
}
