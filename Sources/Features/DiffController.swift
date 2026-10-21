import DiffView
import Foundation

/// The session's handle on the diff view, for navigation the view owns: scrolling is view state,
/// not model state.
@MainActor
final class DiffController {
    weak var view: DiffScrollView?

    init() {}

    var anchor: ScrollAnchor? { view?.anchor }

    func moveFile(by delta: Int) { view?.moveFile(by: delta) }
    func moveHunk(by delta: Int) { view?.moveHunk(by: delta) }
    func page(by delta: Int) { view?.page(by: delta) }
    func scroll(toFile path: String) { view?.scroll(toFile: path) }
    func focus() { view?.focus() }
}
