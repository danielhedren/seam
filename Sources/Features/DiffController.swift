import DiffView
import Foundation

/// The session's handle on the diff view, for navigation the view owns: scrolling is view state,
/// not model state.
@MainActor
public final class DiffController {
    weak var view: DiffScrollView?

    public init() {}

    var anchor: ScrollAnchor? { view?.anchor }

    public func moveFile(by delta: Int) { view?.moveFile(by: delta) }
    public func moveHunk(by delta: Int) { view?.moveHunk(by: delta) }
    public func page(by delta: Int) { view?.page(by: delta) }
    public func scroll(toFile path: String) { view?.scroll(toFile: path) }
    public func focus() { view?.focus() }
}
