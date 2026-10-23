import AppKit
import SwiftUI

/// Collapses the split view column it sits in. On macOS a three-column `NavigationSplitView`
/// ignores `.detailOnly` and writes back `.all`, and its middle column can't collapse, so Hide
/// Sidebars collapses the file list column through its `NSSplitViewItem`.
struct ColumnCollapser: NSViewRepresentable {
    let isCollapsed: Bool

    func makeNSView(context: Context) -> CollapsingView { CollapsingView() }

    func updateNSView(_ view: CollapsingView, context: Context) {
        view.isCollapsed = isCollapsed
    }

    final class CollapsingView: NSView {
        var isCollapsed = false {
            didSet { if isCollapsed != oldValue { apply() } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let item = splitViewItem(), item.isCollapsed != isCollapsed else { return }
            // A window that isn't on screen never runs the animation.
            (window?.isVisible == true ? item.animator() : item).isCollapsed = isCollapsed
        }

        private func splitViewItem() -> NSSplitViewItem? {
            var view = superview
            while let current = view {
                if let split = current as? NSSplitView,
                    let controller = split.delegate as? NSSplitViewController
                {
                    return controller.splitViewItems.first {
                        isDescendant(of: $0.viewController.view)
                    }
                }
                view = current.superview
            }
            return nil
        }
    }
}
