import SwiftUI

/// The worktree list above the commit list. `VSplitView` lays its panes out again whenever the
/// bottom one is replaced, which every worktree switch does, so the divider is drawn here and
/// its position remembered.
struct SidebarSplit<Top: View, Bottom: View>: View {
    @ViewBuilder let top: Top
    @ViewBuilder let bottom: Bottom
    @AppStorage("seam.commitListHeight") private var bottomHeight = 240.0
    @State private var dragStart: Double?

    private static var minimumHeight: Double { 80 }

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.height
            let height = clamped(bottomHeight, in: total)
            VStack(spacing: 0) {
                top.frame(maxHeight: .infinity)
                Divider()
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .pointerStyle(.rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = dragStart ?? height
                                dragStart = start
                                bottomHeight = clamped(start - drag.translation.height, in: total)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                bottom.frame(height: height)
            }
        }
    }

    private func clamped(_ height: Double, in total: Double) -> Double {
        min(max(height, Self.minimumHeight), max(total - Self.minimumHeight, Self.minimumHeight))
    }
}
