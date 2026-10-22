import AppKit

/// The text field of a draft's composer row (SPEC §7.7). The canvas draws the row's frame and
/// keeps this view inside it; the text itself belongs to Features, through the callbacks.
@MainActor
final class DraftEditor: NSScrollView, NSTextViewDelegate {
    let textView = DraftTextView()
    var onChange: ((String) -> Void)?
    /// The editor's inset from the composer's frame.
    static let margin = 8.0
    private static let containerInset = 2.0
    private static let padding = 5.0
    /// From the composer's frame to the typed text, where the frame's title and hints line up.
    static let textInset = margin + containerInset + padding

    init(text: String, font: NSFont) {
        super.init(frame: .zero)
        textView.string = text
        textView.font = font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: Self.containerInset, height: 4)
        textView.textContainer?.lineFragmentPadding = Self.padding
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(
            width: Double.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.delegate = self
        documentView = textView
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
    }

    required init?(coder: NSCoder) { nil }

    func textDidChange(_ notification: Notification) {
        onChange?(textView.string)
    }
}

/// ⌘↩ submits and Escape cancels.
@MainActor
final class DraftTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var placeholder = ""

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // Key equivalents reach every view in the window, so only the focused editor takes ⌘↩.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard window?.firstResponder === self, modifiers == .command,
            event.charactersIgnoringModifiers == "\r"
        else { return super.performKeyEquivalent(with: event) }
        onSubmit?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        NSAttributedString(string: placeholder, attributes: attributes).draw(
            at: NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y))
    }
}
