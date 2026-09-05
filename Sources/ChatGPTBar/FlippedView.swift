import AppKit

/// Top-left origin container, used as the document view of scrollable forms.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
