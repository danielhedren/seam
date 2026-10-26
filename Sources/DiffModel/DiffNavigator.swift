import SeamCore

/// What the review models ask of the diff view: scrolling and the reader's place are view state
/// (SPEC §8.2), so the models drive the view through this instead of owning it.
@MainActor
public protocol DiffNavigator: AnyObject {
    var anchor: ScrollAnchor? { get }
    var readingLocation: (path: String, line: Int)? { get }
    var selectedText: String? { get }
    var commentTarget: (path: String, side: ThreadAnchor.Side, lines: ClosedRange<Int>)? { get }

    func moveFile(by delta: Int)
    func moveHunk(by delta: Int)
    func page(by delta: Int)
    func scroll(toFile path: String)
    func scroll(toLine line: Int, inFile path: String, oldSide: Bool)
    func focus()
    func search(_ query: TextQuery)
    func showMatch(inFile path: String, line: Int, isOld: Bool, occurrence: Int)
    func moveToMatch(by delta: Int)
}
