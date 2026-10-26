import DiffModel
import Foundation
import SeamCore

/// The session's handle on the diff view, for navigation the view owns: scrolling is view state,
/// not model state.
@MainActor
final class DiffController {
    weak var view: (any DiffNavigator)?

    init() {}

    var anchor: ScrollAnchor? { view?.anchor }

    func moveFile(by delta: Int) { view?.moveFile(by: delta) }
    func moveHunk(by delta: Int) { view?.moveHunk(by: delta) }
    func page(by delta: Int) { view?.page(by: delta) }
    func scroll(toFile path: String) { view?.scroll(toFile: path) }
    func focus() { view?.focus() }
    func search(_ query: TextQuery) { view?.search(query) }
    func showMatch(inFile path: String, line: Int, isOld: Bool, occurrence: Int) {
        view?.showMatch(inFile: path, line: line, isOld: isOld, occurrence: occurrence)
    }
    var readingLocation: (path: String, line: Int)? { view?.readingLocation }
    var selectedText: String? { view?.selectedText }
    var commentTarget: (path: String, side: ThreadAnchor.Side, lines: ClosedRange<Int>)? {
        view?.commentTarget
    }
    func scroll(toLine line: Int, inFile path: String, side: ThreadAnchor.Side) {
        view?.scroll(toLine: line, inFile: path, oldSide: side == .old)
    }
    func moveToMatch(by delta: Int) { view?.moveToMatch(by: delta) }
}
