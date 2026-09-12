/// The panel's native search input (V2-11). A retained NavigationStack root
/// can reject SwiftUI FocusState requests without calling makeFirstResponder.
/// Keep the actual NSTextField here so Back and Clear apply their existing
/// focus intent directly, without scheduling retries or searching a view tree.
import AppKit
import SwiftUI

struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let accessibilityLabel: String
    let onMoveSelection: (Int) -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> HistorySearchTextField {
        HistorySearchTextField()
    }

    func updateNSView(_ field: HistorySearchTextField, context: Context) {
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        field.alignment = context.environment.layoutDirection == .rightToLeft ? .right : .left
        field.onTextChange = { value in
            text = value
        }
        field.onFocusChange = { focused in
            if isFocused != focused { isFocused = focused }
        }
        field.onMoveSelection = onMoveSelection
        field.onSubmit = onSubmit
        field.update(text: text, isFocused: isFocused)
    }
}

@MainActor
final class HistorySearchTextField: NSTextField, NSTextFieldDelegate {
    var onTextChange: (String) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    var onMoveSelection: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    private var wantsFocus = false

    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        font = .systemFont(ofSize: NSFont.systemFontSize)
        focusRingType = .none
        delegate = self
        setAccessibilityIdentifier("clipy.search.field")
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    func update(text: String, isFocused: Bool) {
        // SwiftUI updates during composition must not replace the field
        // editor's marked text or insertion/selection range.
        if !stringValue.utf8.elementsEqual(text.utf8),
           !((currentEditor() as? NSTextView)?.hasMarkedText() ?? false) {
            stringValue = text
        }
        wantsFocus = isFocused
        applyFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFocus()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { beganEditing() }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // Cell-driven editing can bypass the control's responder override.
        // Publish that focus before the next bare Space reaches the panel.
        if let editor = currentEditor(), window?.firstResponder === editor {
            beganEditing()
        }
    }

    private func applyFocus() {
        guard let window else { return }
        let ownsEditor = currentEditor().map { window.firstResponder === $0 } ?? false
        if wantsFocus, !ownsEditor {
            window.makeFirstResponder(self)
        } else if !wantsFocus, ownsEditor {
            window.makeFirstResponder(nil)
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        beganEditing()
    }

    private func beganEditing() {
        if let editor = currentEditor() as? NSTextView {
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
        }
        wantsFocus = true
        onFocusChange(true)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        wantsFocus = false
        onFocusChange(false)
    }

    func controlTextDidChange(_ notification: Notification) {
        onTextChange(stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Candidate navigation and confirmation belong to the input method.
        // FloatingPanel separately preserves marked Return/Escape dispatch.
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            onMoveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            onMoveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit()
        default:
            return false
        }
        return true
    }
}
