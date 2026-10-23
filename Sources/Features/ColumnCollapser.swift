import AppKit
import SwiftUI

/// Hides and shows both sidebars in one animation. On macOS a three-column `NavigationSplitView`
/// ignores `.detailOnly` and its middle column can't collapse, so going to or from `.diffOnly`
/// collapses the two columns' `NSSplitViewItem`s directly; SwiftUI then reports the sidebar's
/// state through the visibility binding. Sits in the file list column.
struct ColumnCollapser: NSViewRepresentable {
    let columns: RepoSession.Columns

    func makeNSView(context: Context) -> CollapsingView { CollapsingView() }

    func updateNSView(_ view: CollapsingView, context: Context) {
        view.columns = columns
    }

    final class CollapsingView: NSView {
        var columns = RepoSession.Columns.all {
            didSet {
                if columns != oldValue, columns == .diffOnly || oldValue == .diffOnly { apply() }
            }
        }
        private var fileListWidth: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if columns == .diffOnly { apply() }
        }

        private func apply() {
            guard let (_, sidebar, fileList) = items() else { return }
            let hidesFiles = columns == .diffOnly
            if hidesFiles, !fileList.isCollapsed {
                fileListWidth = fileList.viewController.view.frame.width
            }
            // SwiftUI makes the file list non-collapsible, and such a column slides without
            // keeping its width; collapsible only while hidden, so a drag can't close it.
            fileList.canCollapse = true
            // A window that isn't on screen never runs the animation.
            let animates = window?.isVisible == true
            NSAnimationContext.runAnimationGroup { _ in
                for (item, collapsed) in [(sidebar, columns != .all), (fileList, hidesFiles)]
                where item.isCollapsed != collapsed {
                    (animates ? item.animator() : item).isCollapsed = collapsed
                }
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.finish() }
            }
            if !animates { finish() }
        }

        /// Once the file list is back: not collapsible again, and at the width it had.
        private func finish() {
            guard columns != .diffOnly, let (controller, _, fileList) = items() else { return }
            fileList.canCollapse = false
            let split = controller.splitView
            let view = fileList.viewController.view
            guard let width = fileListWidth, view.frame.width != width,
                let index = split.arrangedSubviews.firstIndex(of: view),
                index < split.arrangedSubviews.count - 1
            else { return }
            split.setPosition(view.frame.minX + width, ofDividerAt: index)
        }

        private func items() -> (NSSplitViewController, NSSplitViewItem, NSSplitViewItem)? {
            guard let controller = splitViewController(),
                let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar }),
                let fileList = controller.splitViewItems.first(where: {
                    isDescendant(of: $0.viewController.view)
                })
            else { return nil }
            return (controller, sidebar, fileList)
        }

        private func splitViewController() -> NSSplitViewController? {
            var view = superview
            while let current = view {
                if let split = current as? NSSplitView,
                    let controller = split.delegate as? NSSplitViewController
                {
                    return controller
                }
                view = current.superview
            }
            return nil
        }
    }
}
