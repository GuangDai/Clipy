import AppKit
import SwiftUI

/// The workflow playground edits literal input (V2-13). SwiftUI's
/// autocorrectionDisabled does not disable NSTextView's independent text
/// replacements: the system's double-space replacement can still insert a
/// period. Own this one text view so its substitutions never alter the source.
struct BuiltInAutomationSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String

    func makeNSView(context: Context) -> BuiltInAutomationSourceScrollView {
        BuiltInAutomationSourceScrollView()
    }

    func updateNSView(_ scroll: BuiltInAutomationSourceScrollView, context: Context) {
        guard let editor = scroll.documentView as? BuiltInAutomationSourceTextView else { return }
        editor.onTextChange = { text = $0 }
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.update(text: text)
    }
}

/// An empty text document still fills its viewport and accepts a click.
/// Re-tile after native window resizing without replacing the live editor.
@MainActor
final class BuiltInAutomationSourceScrollView: NSScrollView {
    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false
        documentView = BuiltInAutomationSourceTextView()
    }

    required init?(coder: NSCoder) { nil }

    override func tile() {
        super.tile()
        guard let editor = documentView as? BuiltInAutomationSourceTextView else { return }
        let viewport = contentView.bounds.size
        let filledPreviousViewport = editor.frame.height <= editor.minSize.height
        editor.minSize = NSSize(width: 0, height: viewport.height)
        let height = filledPreviousViewport ? viewport.height : max(viewport.height, editor.frame.height)
        let size = NSSize(width: viewport.width, height: height)
        if editor.frame.size != size { editor.setFrameSize(size) }
    }
}

@MainActor
final class BuiltInAutomationSourceTextView: NSTextView, NSTextViewDelegate {
    var onTextChange: (String) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        isRichText = false
        importsGraphics = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textColor = .textColor
        insertionPointColor = .textColor
        backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: 6, height: 6)
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: 0, height: .greatestFiniteMagnitude)
        delegate = self
        setAccessibilityIdentifier("clipy.workflow.source")
        configureLiteralInput()
    }

    required init?(coder: NSCoder) { nil }

    override func becomeFirstResponder() -> Bool {
        // A reused editor can inherit text-system preferences when it starts
        // editing. Scope the opt-out to this field, never UserDefaults or the
        // shared spell checker. Input-method composition remains AppKit's.
        let accepted = super.becomeFirstResponder()
        configureLiteralInput()
        return accepted
    }

    func update(text: String) {
        // Binding echoes must not reset the caret, undo or marked Chinese
        // input. Compare exact bytes: String equality normalizes NFC/NFD.
        guard !hasMarkedText(), !string.utf8.elementsEqual(text.utf8) else { return }
        let selection = selectedRange()
        string = text
        let length = (text as NSString).length
        let location = min(selection.location, length)
        setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
    }

    func textDidChange(_ notification: Notification) {
        onTextChange(string)
    }

    private func configureLiteralInput() {
        isAutomaticTextReplacementEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        enabledTextCheckingTypes = 0
        smartInsertDeleteEnabled = false
    }
}
