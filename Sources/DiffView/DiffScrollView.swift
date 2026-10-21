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
    /// The file at the top of the view, for the file list to follow.
    public var onCurrentFileChange: ((String?) -> Void)?

    public var isStale: Bool {
        get { canvas.isStale }
        set { canvas.isStale = newValue }
    }

    private let canvas = DiffCanvasView()
    private let sticky = DiffStickyHeaderView()
    private var reportedFile: String?
    /// After a jump to a file, the clip view's top the jump landed on. A short file near the end
    /// can't reach the top, so until the reader scrolls away the jumped-to file stays current.
    private var jumpedTop: Double?

    public init() {
        super.init(frame: .zero)
        documentView = canvas
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        sticky.font = canvas.font
        sticky.increaseContrast = canvas.increaseContrast
        sticky.isHidden = true
        sticky.onClick = { [weak self] in
            guard let self, let file = sticky.file else { return }
            onToggleCollapse?(file.diff.path)
        }
        addSubview(sticky)
        setAccessibilityLabel(String(localized: "Diff", bundle: .module))
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
        sticky.needsDisplay = true
    }

    required init?(coder: NSCoder) { nil }

    private var layout: DiffLayout { canvas.layout }
    private var headerHeight: Double { layout.metrics.fileHeaderHeight }
    private var visibleTop: Double { contentView.bounds.minY }

    public func show(_ content: DiffContent, position: Position) {
        let kept = position == .keep ? anchor : nil
        canvas.show(content)
        canvas.setVisibleWidth(contentSize.width)
        switch position {
        case .keep:
            if let kept { restore(kept) }
        case .top: scroll(toY: 0)
        case .anchor(let anchor): restore(anchor)
        case .file(let path): scroll(toFile: path)
        }
        updateSticky()
    }

    /// The line just below the sticky header, which is what the reader is looking at.
    public var anchor: ScrollAnchor? {
        layout.anchor(atY: visibleTop + headerHeight, paths: canvas.paths)
    }

    public var currentFilePath: String? {
        guard let row = layout.row(at: visibleTop + headerHeight) else { return nil }
        let file = layout.rows[row].file
        return file < canvas.paths.count ? canvas.paths[file] : nil
    }

    public func focus() {
        window?.makeFirstResponder(canvas)
    }

    public var isFocused: Bool { window?.firstResponder === canvas }

    public func scroll(toFile path: String) {
        guard let file = canvas.paths.firstIndex(of: path), let row = layout.headerRow(ofFile: file)
        else { return }
        scroll(toY: layout.top(of: row))
        jumpedTop = visibleTop
        reportedFile = path
        onCurrentFileChange?(path)
    }

    /// Next or previous file header, relative to the file under the sticky header.
    public func moveFile(by delta: Int) {
        guard let current = layout.row(at: visibleTop + 1) else { return }
        let target =
            delta > 0
            ? layout.nextStop(after: current, files: true)
            : layout.previousStop(before: current, files: true)
        if let target { scroll(toY: layout.top(of: target)) }
    }

    /// Next or previous hunk across files, placed just below the sticky header.
    public func moveHunk(by delta: Int) {
        guard let current = layout.row(at: visibleTop + headerHeight + 1) else { return }
        let target =
            delta > 0
            ? layout.nextStop(after: current, files: false)
            : layout.previousStop(before: current, files: false)
        if let target { scroll(toY: layout.top(of: target) - headerHeight) }
    }

    public func page(by delta: Int) {
        let step = max(contentSize.height - headerHeight - layout.metrics.lineHeight * 2, 1)
        scroll(toY: visibleTop + Double(delta) * step)
    }

    func scrollLine(by delta: Int) {
        scroll(toY: visibleTop + Double(delta) * layout.metrics.lineHeight * 3)
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

    public override func tile() {
        super.tile()
        canvas.setVisibleWidth(contentSize.width)
        updateSticky()
    }

    public override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
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
        if sticky.file != reviewFile
            || sticky.collapsed != canvas.collapsed.contains(reviewFile.diff.path)
        {
            sticky.file = reviewFile
            sticky.collapsed = canvas.collapsed.contains(reviewFile.diff.path)
            sticky.needsDisplay = true
        }
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
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
