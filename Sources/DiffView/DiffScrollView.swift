import AppKit
import SeamCore

/// The diff pane: a scroll view around the canvas, with the sticky file header and keyboard
/// navigation. Features drives it through `show` and the move methods.
@MainActor
public final class DiffScrollView: NSScrollView {
    public enum Position: Equatable {
        /// Keep the reader on the same file and line across a reload (SPEC §8.6).
        case keep
        case top
        case anchor(ScrollAnchor)
        case file(String)
    }

    public var onToggleCollapse: ((String) -> Void)? {
        didSet { canvas.onToggleCollapse = onToggleCollapse }
    }
    public var onFocusChange: ((Bool) -> Void)? {
        didSet { canvas.onFocusChange = onFocusChange }
    }
    /// A gap's control was clicked: file path, gap index, direction.
    public var onExpand: ((String, Int, ExpandDirection) -> Void)? {
        didSet { canvas.onExpand = onExpand }
    }
    /// The context menu for a file header, by path.
    public var menuForFile: ((String) -> NSMenu?)? {
        didSet {
            canvas.menuForFile = menuForFile
            sticky.menuForFile = { [weak self] in
                self?.sticky.file.flatMap { self?.menuForFile?($0.diff.path) }
            }
        }
    }
    /// The card's contents, made when its row first shows (SPEC §7.7).
    public var makeCardView: ((DiffCard) -> any DiffCardView)? {
        didSet { canvas.makeCardView = makeCardView }
    }
    /// After each update: whether the open thread has no row, its lines being hidden in a gap.
    public var onOpenThreadHidden: ((Bool) -> Void)?
    /// Escape in the diff with nothing selected, while a card shows.
    public var onCloseCard: (() -> Void)? {
        didSet { canvas.onCloseCard = onCloseCard }
    }
    /// The viewed checkbox in a file header was clicked.
    public var onToggleViewed: ((String) -> Void)? {
        didSet { canvas.onToggleViewed = onToggleViewed }
    }
    /// The file at the top of the view, for the file list to follow.
    public var onCurrentFileChange: ((String?) -> Void)?

    public var isStale: Bool {
        get { canvas.isStale }
        set { canvas.isStale = newValue }
    }

    /// Find results: the current match's number (from 1) and the total, after every search,
    /// move or content change.
    public var onSearchResult: ((_ current: Int?, _ total: Int) -> Void)?

    private let canvas = DiffCanvasView()
    private var query = TextQuery()
    private var matches: [DiffMatch] = []
    private var currentMatch: Int?
    /// A match `showMatch` asked for in a file that isn't laid out yet (it was collapsed).
    private var pendingMatch: (path: String, line: Int, isOld: Bool, occurrence: Int)?
    private let sticky = DiffStickyHeaderView()
    private var reportedFile: String?
    /// After a jump to a file, the clip view's top the jump landed on. A short file near the end
    /// can't reach the top, so until the reader scrolls away the jumped-to file stays current.
    private var jumpedTop: Double?
    private var visibleLeft = 0.0

    public init() {
        super.init(frame: .zero)
        documentView = canvas
        hasVerticalScroller = true
        scrollerInsets.top = Self.fileHeaderHeight(for: canvas.font)
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        sticky.font = canvas.font
        sticky.increaseContrast = canvas.increaseContrast
        sticky.isHidden = true
        sticky.onClick = { [weak self] onViewed in
            guard let self, let file = sticky.file else { return }
            if onViewed {
                onToggleViewed?(file.diff.path)
            } else {
                onToggleCollapse?(file.diff.path)
            }
        }
        addSubview(sticky)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    /// Forces Increase Contrast on or off; nil follows the system.
    var increaseContrastOverride: Bool? {
        get { canvas.increaseContrastOverride }
        set {
            canvas.increaseContrastOverride = newValue
            displayOptionsChanged()
        }
    }

    @objc private func displayOptionsChanged() {
        sticky.increaseContrast = canvas.increaseContrast
        canvas.appearanceOptionsChanged()
    }

    required init?(coder: NSCoder) { nil }

    private var layout: DiffLayout { canvas.layout }
    private var headerHeight: Double { layout.metrics.fileHeaderHeight }
    private var visibleTop: Double { contentView.bounds.minY }

    public func show(_ content: DiffContent, position: Position) {
        let kept = position == .keep ? anchor : nil
        let matchRow = currentMatch.map { matches[$0].row }
        let previousDraft = canvas.shownDraft
        let previousThread = canvas.shownOpenThread
        canvas.show(content)
        if !query.isEmpty { refreshMatches(near: matchRow ?? 0, reveal: false) }
        defer {
            applyPendingMatch()
            pendingMatch = nil
        }
        canvas.setVisibleWidth(contentSize.width)
        switch position {
        case .keep:
            if let kept { restore(kept) }
        case .top: scroll(toY: 0)
        case .anchor(let anchor): restore(anchor)
        case .file(let path): scroll(toFile: path)
        }
        if let draft = content.draft, draft != previousDraft { reveal(canvas.draftRow) }
        if let open = content.openThread, open != previousThread { reveal(canvas.openThreadRow) }
        onOpenThreadHidden?(content.openThread != nil && canvas.openThreadRow == nil)
        updateSticky()
    }

    /// Scrolls a new composer or an opened thread fully into view, its top first when it's
    /// taller than the view.
    private func reveal(_ row: Int?) {
        guard let row else { return }
        let top = layout.top(of: row)
        let bottom = top + layout.height(of: row)
        if top < visibleTop + headerHeight || bottom - top > contentSize.height - headerHeight {
            scroll(toY: top - headerHeight)
        } else if bottom > visibleTop + contentSize.height {
            scroll(toY: bottom - contentSize.height)
        }
    }

    /// The line just below the sticky header, which is what the reader is looking at.
    public var anchor: ScrollAnchor? {
        layout.anchor(atY: visibleTop + headerHeight, paths: canvas.paths)
    }

    /// The context menu for a right click on lines, which selects them first unless the click
    /// is inside the selection.
    public var menuForLines: (() -> NSMenu?)? {
        didSet { canvas.menuForLines = menuForLines }
    }

    public var onOpenThread: ((String) -> Void)? {
        didSet { canvas.onOpenThread = onOpenThread }
    }

    /// Where `c` puts a new thread (SPEC §7.7): the selected lines, else the one being read.
    public var commentTarget: (path: String, side: ThreadAnchor.Side, lines: ClosedRange<Int>)? {
        let y = canvas.selection.map { layout.top(of: $0.head.row) } ?? visibleTop + headerHeight
        guard let target = canvas.commentTarget(fallback: layout.row(at: y)),
            target.file < canvas.paths.count
        else { return nil }
        return (canvas.paths[target.file], target.side, target.lines)
    }

    /// The selected text, for ⌘F to search for.
    public var selectedText: String? { canvas.selectedText }

    /// The file and line the reader is on, for "open in editor": the selection's line if there
    /// is one, else the line under the sticky header.
    public var readingLocation: (path: String, line: Int)? {
        let y = canvas.selection.map { layout.top(of: $0.head.row) } ?? visibleTop + headerHeight
        guard let row = layout.row(at: y), let location = layout.location(atOrAfter: row) else {
            return nil
        }
        return (canvas.paths[location.file], location.line)
    }

    var currentFilePath: String? {
        guard let row = layout.row(at: visibleTop + headerHeight) else { return nil }
        let file = layout.rows[row].file
        return file < canvas.paths.count ? canvas.paths[file] : nil
    }

    public func focus() {
        window?.makeFirstResponder(canvas)
    }

    /// A new window has nothing focused, and single-letter keys only apply while the diff or file
    /// list has focus; taking it here means `j`, `n` and `v` work as soon as the diff appears.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window.firstResponder === window else { return }
        window.makeFirstResponder(canvas)
    }

    var isFocused: Bool { window?.firstResponder === canvas }

    public func scroll(toFile path: String) {
        guard let file = canvas.paths.firstIndex(of: path), let row = layout.headerRow(ofFile: file)
        else { return }
        scroll(toY: layout.top(of: row))
        jumpedTop = visibleTop
        reportedFile = path
        onCurrentFileChange?(path)
    }

    /// Puts a line a little below the top, so the lines above it give context.
    public func scroll(toLine line: Int, inFile path: String, oldSide: Bool) {
        let anchor = ScrollAnchor(path: path, line: line, isOldSide: oldSide, offset: 0)
        guard let y = layout.y(for: anchor, paths: canvas.paths) else { return }
        scroll(toY: max(y - layout.metrics.lineHeight * 4 - headerHeight, 0))
        jumpedTop = visibleTop
    }

    /// Next or previous file header, relative to the file under the sticky header.
    public func moveFile(by delta: Int) {
        let target =
            delta > 0
            ? layout.nextStop(below: visibleTop + 1, files: true)
            : layout.previousStop(above: visibleTop - 1, files: true)
        if let target { scroll(toY: layout.top(of: target)) }
    }

    /// Next or previous hunk across files, placed just below the sticky header.
    public func moveHunk(by delta: Int) {
        let reading = visibleTop + headerHeight
        let target =
            delta > 0
            ? layout.nextStop(below: reading + 1, files: false)
            : layout.previousStop(above: reading - 1, files: false)
        if let target { scroll(toY: layout.top(of: target) - headerHeight) }
    }

    public func page(by delta: Int) {
        let step = max(contentSize.height - headerHeight - layout.metrics.lineHeight * 2, 1)
        scroll(toY: visibleTop + Double(delta) * step)
    }

    func scrollLine(by delta: Int) {
        scroll(toY: visibleTop + Double(delta) * layout.metrics.lineHeight * 3)
    }

    /// The sticky file header's height for `font`; the panes beside the diff give their own
    /// headers this height, so the header rows meet in one line (SPEC §9).
    public static func fileHeaderHeight(for font: NSFont) -> Double {
        DiffCanvasView.metrics(for: font).fileHeaderHeight
    }

    public func setFont(_ font: NSFont) {
        guard font != canvas.font else { return }
        let anchor = anchor
        canvas.setFont(font)
        sticky.font = font
        // The scroller starts below the sticky header rather than over its borders.
        scrollerInsets.top = Self.fileHeaderHeight(for: font)
        if let anchor { restore(anchor) }
        updateSticky()
    }

    // MARK: - Find

    /// Searches as the reader types, starting from the line at the top of the view.
    public func search(_ query: TextQuery) {
        guard query != self.query else { return }
        self.query = query
        let top = layout.row(at: visibleTop + headerHeight) ?? 0
        refreshMatches(near: top, reveal: true)
    }

    public func moveToMatch(by delta: Int) {
        guard !matches.isEmpty else { return }
        let current = currentMatch ?? (delta > 0 ? -1 : 0)
        currentMatch = (current + delta + matches.count) % matches.count
        publishMatches(reveal: true)
    }

    public func search(_ text: String) {
        search(TextQuery(text))
    }

    /// Makes the `occurrence`th match on a line current and scrolls to it. A file that isn't
    /// laid out yet gets one more try when the next content arrives.
    public func showMatch(inFile path: String, line: Int, isOld: Bool, occurrence: Int) {
        pendingMatch = (path, line, isOld, occurrence)
        applyPendingMatch()
    }

    private func applyPendingMatch() {
        guard let target = pendingMatch, let file = canvas.paths.firstIndex(of: target.path),
            let row = layout.row(forLine: target.line, inFile: file, isOld: target.isOld)
        else { return }
        pendingMatch = nil
        // A context line shows on both sides of a split row; its match counts on the new one.
        let side: DiffSide =
            layout.text(of: row, side: .unified) != nil ? .unified : target.isOld ? .left : .right
        let onLine = matches.indices.filter { matches[$0].row == row && matches[$0].side == side }
        guard !onLine.isEmpty else {
            scroll(toLine: target.line, inFile: target.path, oldSide: target.isOld)
            return
        }
        currentMatch = onLine[min(target.occurrence, onLine.count - 1)]
        publishMatches(reveal: true)
    }

    private func refreshMatches(near row: Int, reveal: Bool) {
        matches = DiffSearch.matches(query, in: layout)
        currentMatch = DiffSearch.nearest(to: row, in: matches)
        publishMatches(reveal: reveal)
    }

    private func publishMatches(reveal: Bool) {
        var byRow: [Int: [(side: DiffSide, range: Range<Int>, isCurrent: Bool)]] = [:]
        for (index, match) in matches.enumerated() {
            byRow[match.row, default: []].append((match.side, match.range, index == currentMatch))
        }
        canvas.findMatches = byRow
        // A view without a size yet (its first update) has nothing to scroll.
        if reveal, let currentMatch, contentSize.height > headerHeight {
            let row = matches[currentMatch].row
            let top = layout.top(of: row)
            let visible = visibleTop + headerHeight..<visibleTop + contentSize.height
            if !visible.contains(top) {
                scroll(toY: top - headerHeight - contentSize.height / 3)
            }
        }
        onSearchResult?(currentMatch.map { $0 + 1 }, matches.count)
    }

    private func restore(_ anchor: ScrollAnchor) {
        guard let y = layout.y(for: anchor, paths: canvas.paths) else { return }
        scroll(toY: y - headerHeight)
    }

    private func scroll(toY y: Double) {
        let maxY = max(layout.totalHeight - contentSize.height, 0)
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: min(max(y, 0), maxY)))
        reflectScrolledClipView(contentView)
    }

    /// With wrapping, a new width changes row heights, so the reader's line is restored.
    public override func tile() {
        super.tile()
        let anchor = anchor
        if canvas.setVisibleWidth(contentSize.width), let anchor { restore(anchor) }
        updateSticky()
    }

    public override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        if contentView.bounds.minX != visibleLeft {
            visibleLeft = contentView.bounds.minX
            canvas.horizontalScrollDidChange()
        }
        // The canvas only sets cursor rects for the rows in view.
        window?.invalidateCursorRects(for: canvas)
        updateSticky()
        if let jumpedTop {
            if jumpedTop == visibleTop { return }
            self.jumpedTop = nil
        }
        let current = currentFilePath
        if current != reportedFile {
            reportedFile = current
            onCurrentFileChange?(current)
        }
    }

    /// Shows the current file's header pinned at the top, pushed up by the next file's header.
    private func updateSticky() {
        let top = visibleTop
        guard let row = layout.row(at: top),
            let header = layout.headerRow(ofFile: layout.rows[row].file),
            layout.top(of: header) < top
        else {
            sticky.isHidden = true
            return
        }
        let file = layout.rows[row].file
        var push = 0.0
        if let next = layout.headerRow(ofFile: file + 1) {
            push = max(top + headerHeight - layout.top(of: next), 0)
        }
        let content = contentView.frame
        let y = isFlipped ? content.minY - push : content.maxY - headerHeight + push
        sticky.frame = NSRect(x: content.minX, y: y, width: content.width, height: headerHeight)
        let reviewFile = canvas.review.files[file]
        sticky.file = reviewFile
        sticky.collapsed = canvas.collapsed.contains(reviewFile.diff.path)
        sticky.viewed = canvas.viewed[reviewFile.diff.path] ?? .unviewed
        sticky.isHidden = false
    }
}

extension DiffCanvasView {
    override func keyDown(with event: NSEvent) {
        guard let scroll = enclosingScrollView as? DiffScrollView else {
            super.keyDown(with: event)
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        switch event.specialKey {
        case .pageDown?: scroll.page(by: 1)
        case .pageUp?: scroll.page(by: -1)
        case .downArrow?: scroll.scrollLine(by: 1)
        case .upArrow?: scroll.scrollLine(by: -1)
        default:
            if event.charactersIgnoringModifiers == " " {
                scroll.page(by: shift ? -1 : 1)
            } else if event.keyCode == 53 {
                cancelOperation(nil)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// Escape drops the selection, and with it what `c` would comment on; with nothing
    /// selected it closes the card.
    override func cancelOperation(_ sender: Any?) {
        if selection == nil, shownCard != nil {
            onCloseCard?()
        } else {
            selection = nil
        }
    }
}
