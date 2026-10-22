import AppKit
import SeamCore
import SwiftUI

/// The per-file actions offered by both the file list's and the diff headers' context menus.
@MainActor
enum FileActions {
    struct Action {
        var title: String
        var run: () -> Void
    }

    /// The diff's menu for the selected lines (SPEC §7.7).
    static func lineMenu(in session: RepoSession) -> NSMenu? {
        guard let target = session.diff.commentTarget else { return nil }
        let lines = target.lines
        let comment =
            lines.count == 1
            ? String(localized: "Comment on Line \(lines.lowerBound)…", bundle: .module)
            : String(
                localized: "Comment on Lines \(lines.lowerBound)–\(lines.upperBound)…",
                bundle: .module)
        return menu([
            [Action(title: comment) { session.comment() }],
            [
                Action(title: String(localized: "Copy", bundle: .module)) {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                },
                Action(title: String(localized: "Open in Editor", bundle: .module)) {
                    session.openInEditor()
                },
            ],
        ])
    }

    static func actions(for path: String, in session: RepoSession) -> [[Action]] {
        let viewed = session.selected?.viewedStatus(path) == .viewed
        let collapsed = session.selected?.collapsed.contains(path) == true
        return [
            [
                Action(title: String(localized: "Open in Editor", bundle: .module)) {
                    session.openInEditor(file: path)
                },
                Action(title: String(localized: "Reveal in Finder", bundle: .module)) {
                    session.revealInFinder(path)
                },
            ],
            [
                Action(title: String(localized: "Copy Path", bundle: .module)) {
                    session.copyPath(path, relative: false)
                },
                Action(title: String(localized: "Copy Relative Path", bundle: .module)) {
                    session.copyPath(path, relative: true)
                },
            ],
            [
                Action(
                    title: viewed
                        ? String(localized: "Mark as Not Viewed", bundle: .module)
                        : String(localized: "Mark as Viewed", bundle: .module)
                ) { session.toggleViewed(path, advance: false) },
                Action(
                    title: collapsed
                        ? String(localized: "Expand File", bundle: .module)
                        : String(localized: "Collapse File", bundle: .module)
                ) { session.toggleCollapsed(path) },
            ],
        ]
    }

    /// For the AppKit diff view's file headers.
    static func menu(for path: String, in session: RepoSession) -> NSMenu {
        menu(actions(for: path, in: session))
    }

    private static func menu(_ groups: [[Action]]) -> NSMenu {
        let menu = NSMenu()
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for action in group { menu.addItem(ClosureMenuItem(action.title, action.run)) }
        }
        return menu
    }
}

/// A menu item that runs a closure, for menus built at click time.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        handler = {}
        super.init(coder: coder)
    }

    @objc private func run() { handler() }
}

/// The SwiftUI side, for the file list.
struct FileContextMenu: View {
    let path: String
    let session: RepoSession

    var body: some View {
        let groups = FileActions.actions(for: path, in: session)
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(groups[index].indices, id: \.self) { item in
                Button(groups[index][item].title, action: groups[index][item].run)
            }
        }
    }
}
