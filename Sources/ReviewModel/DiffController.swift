import DiffModel
import Foundation
import SeamCore

/// The session's handle on the diff view, for navigation the view owns: scrolling is view state,
/// not model state.
@MainActor
package final class DiffController {
    package weak var view: (any DiffNavigator)?

    /// Called before every jump, so Back can return from it (SPEC §7.4.1).
    var willJump: (() -> Void)?

    init() {}

    var anchor: ScrollAnchor? { view?.anchor }

    package func moveFile(by delta: Int) { view?.moveFile(by: delta) }
    package func moveHunk(by delta: Int) { view?.moveHunk(by: delta) }
    package func page(by delta: Int) { view?.page(by: delta) }
    package func scroll(toFile path: String) {
        willJump?()
        view?.scroll(toFile: path)
    }
    /// Back and Forward's own move, which isn't a jump to return from.
    func restore(_ anchor: ScrollAnchor) { view?.scroll(to: anchor) }
    package func focus() { view?.focus() }
    package func search(_ query: TextQuery) { view?.search(query) }
    func showMatch(inFile path: String, line: Int, isOld: Bool, occurrence: Int) {
        willJump?()
        view?.showMatch(inFile: path, line: line, isOld: isOld, occurrence: occurrence)
    }
    var readingLocation: (path: String, line: Int)? { view?.readingLocation }
    var selectedText: String? { view?.selectedText }
    package var commentTarget: (path: String, side: ThreadAnchor.Side, lines: ClosedRange<Int>)? {
        view?.commentTarget
    }
    package func scroll(toLine line: Int, inFile path: String, side: ThreadAnchor.Side) {
        willJump?()
        view?.scroll(toLine: line, inFile: path, oldSide: side == .old)
    }
    func moveToMatch(by delta: Int) {
        willJump?()
        view?.moveToMatch(by: delta)
    }
}
