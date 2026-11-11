import AppKit
import CoreText
import GitKit
import SeamCore
import Testing

@testable import DiffModel
@testable import DiffView

@MainActor @Suite(.timeLimit(.minutes(1))) struct WhereYouAreTests {
    private func file(lines: Int) -> ReviewFile {
        var hunk = Hunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: lines, section: "")
        hunk.lines = (1...lines).map {
            DiffLine(kind: .added, text: "line \($0)", oldNumber: nil, newNumber: $0)
        }
        var file = FileDiff(oldPath: nil, newPath: "Delivery.cs", status: .added)
        file.hunks = [hunk]
        return ReviewFile(diff: file)
    }

    private let scopes = [
        SyntaxScope(lines: 9...179, name: "DeliveryHandler"),
        SyntaxScope(lines: 19...59, name: "Handle"),
        SyntaxScope(lines: 99...149, name: "Validate"),
    ]

    @Test func theStickyHeaderNamesTheDefinitionsAroundTheLineUnderItAsTheReaderScrolls() {
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
        view.show(
            DiffContent(
                review: ReviewDiff(scope: .all, files: [file(lines: 200)]),
                syntax: ["Delivery.cs": FileSyntax(newScopes: scopes)]), position: .top)
        #expect(view.shownDefinitions == [], "the header isn't stuck at the top of the file")

        view.scroll(toLine: 44, inFile: "Delivery.cs", oldSide: false)
        #expect(view.anchor?.line == 40)
        #expect(view.shownDefinitions == ["DeliveryHandler", "Handle"])
        view.page(by: 4)
        #expect(view.shownDefinitions == ["DeliveryHandler"], "between the two methods")

        view.scroll(toLine: 124, inFile: "Delivery.cs", oldSide: false)
        #expect(view.shownDefinitions == ["DeliveryHandler", "Validate"])
        view.scroll(toLine: 199, inFile: "Delivery.cs", oldSide: false)
        #expect(view.shownDefinitions == [], "below every definition")
    }

    @Test func outerDefinitionsGiveWayBeforeThePathDoes() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        func pieces(width: Double) -> [String] {
            let header = DiffHeaderDrawing.layout(
                file(lines: 1), viewed: .unviewed, definitions: ["DeliveryHandler", "Handle"],
                in: NSRect(x: 0, y: 0, width: width, height: 28), font: font, palette: .light)
            return header.pieces.map { piece in
                let runs = CTLineGetGlyphRuns(piece.line) as? [CTRun] ?? []
                return String(runs.reduce(0) { $0 + CTRunGetGlyphCount($1) })
            }
        }
        let title = "\("A  Delivery.cs".count)"
        let whole = "\("DeliveryHandler › Handle".count)"
        #expect(pieces(width: 700).prefix(2) == [title, whole])
        // Narrowing the header drops the outer definition, then the inner, before the path.
        var states: [[String]] = []
        for width in stride(from: 700.0, to: 150, by: -5) {
            let state = Array(pieces(width: width).dropLast(3))
            if state != states.last { states.append(state) }
        }
        #expect(states.prefix(3) == [[title, whole], [title, "\("Handle".count)"], [title]])
    }
}
