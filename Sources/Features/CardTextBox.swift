import AppKit
import SwiftUI

/// The card's text box: an AppKit text view, so ⌘↩ and Escape are the box's own keys rather
/// than SwiftUI shortcuts, which a view hosted inside the diff doesn't reliably get. Plain text
/// in the diff's font, no background of its own, a fixed number of lines tall.
struct CardTextBox: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let lines: Int
    /// The cursor goes in once the box is in a window: a new thread's box, not a reply's.
    let takesFocus: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CardTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(
            width: Double.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.string = text
        textView.takesFocus = takesFocus
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scroll.documentView as? CardTextView else { return }
        if textView.string != text { textView.string = text }
        if textView.font != font { textView.font = font }
        textView.placeholder = placeholder
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        textView.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context)
        -> CGSize?
    {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return CGSize(
            width: proposal.width ?? 200, height: (lineHeight * Double(lines)).rounded(.up))
    }
}

/// ⌘↩ submits and Escape cancels; draws its placeholder while empty.
final class CardTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var placeholder = ""
    var takesFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard takesFocus, let window else { return }
        takesFocus = false
        window.makeFirstResponder(self)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // Key equivalents reach every view in the window, so only the focused box takes ⌘↩.
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
        NSAttributedString(string: placeholder, attributes: attributes).draw(
            at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y))
    }
}
