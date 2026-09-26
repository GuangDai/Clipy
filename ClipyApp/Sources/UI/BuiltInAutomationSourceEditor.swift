import AppKit
import SwiftUI

/// The workflow playground edits literal input (V2-13). SwiftUI's
/// autocorrectionDisabled does not disable NSTextView's independent text
/// replacements: the system's double-space replacement can still insert a
/// period. Own this one text view so its substitutions never alter the source.
struct BuiltInAutomationSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let accessibilityLabel: String
    var isEditable = true
    var accessibilityIdentifier = "clipy.workflow.source"
    var requestedSelection: NSRange? = nil
    var selectionRequestID: UUID? = nil
    var usesRuleIndentation = false

    func makeNSView(context: Context) -> BuiltInAutomationSourceScrollView {
        BuiltInAutomationSourceScrollView()
    }

    func updateNSView(_ scroll: BuiltInAutomationSourceScrollView, context: Context) {
        guard let editor = scroll.documentView as? BuiltInAutomationSourceTextView else { return }
        editor.onTextChange = { text = $0 }
        editor.isEditable = isEditable
        editor.allowsUndo = isEditable
        editor.usesRuleIndentation = usesRuleIndentation
        editor.setAccessibilityLabel(accessibilityLabel)
        editor.setAccessibilityIdentifier(accessibilityIdentifier)
        editor.update(text: text)
        editor.revealSelection(requestedSelection, requestID: selectionRequestID)
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
        borderType = .bezelBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor
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
    private var lastSelectionRequestID: UUID?
    var usesRuleIndentation = false

    override func insertTab(_ sender: Any?) {
        guard usesRuleIndentation, isEditable else { super.insertTab(sender); return }
        if selectedRange().length > 0 { indentRuleLines(outdent: false) }
        else { insertText("    ", replacementRange: selectedRange()) }
    }

    override func insertBacktab(_ sender: Any?) {
        guard usesRuleIndentation, isEditable else { super.insertBacktab(sender); return }
        indentRuleLines(outdent: true)
    }

    override func insertNewline(_ sender: Any?) {
        guard usesRuleIndentation, isEditable else { super.insertNewline(sender); return }
        let native = string as NSString
        let selection = selectedRange()
        let line = native.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefix = native.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let indentation = String(prefix.prefix { $0 == " " })
        let opensBlock = prefix.trimmingCharacters(in: .whitespaces).hasSuffix(":")
        insertText("\n" + indentation + (opensBlock ? "    " : ""), replacementRange: selection)
    }

    private func indentRuleLines(outdent: Bool) {
        let native = string as NSString
        let selection = selectedRange()
        // A selection ending at the next line's start does not include that
        // line. All offsets are native UTF-16; only ASCII indentation changes.
        let touched = NSRange(location: selection.location, length: max(0, selection.length - 1))
        let block = native.lineRange(for: touched)
        var cursor = block.location
        var replacement = ""
        var edits: [(location: Int, removed: Int, inserted: Int)] = []
        repeat {
            let line = native.lineRange(for: NSRange(location: cursor, length: 0))
            let end = min(NSMaxRange(line), NSMaxRange(block))
            var removed = 0
            if outdent {
                while removed < 4, cursor + removed < end, native.character(at: cursor + removed) == 32 {
                    removed += 1
                }
            } else {
                replacement += "    "
            }
            replacement += native.substring(with: NSRange(location: cursor + removed, length: end - cursor - removed))
            edits.append((cursor, removed, outdent ? 0 : 4))
            guard end > cursor else { break }
            cursor = end
        } while cursor < NSMaxRange(block)
        guard edits.contains(where: { $0.removed != $0.inserted }) else { return }

        func adjusted(_ offset: Int) -> Int {
            var result = offset
            for edit in edits {
                if offset >= edit.location + edit.removed { result += edit.inserted - edit.removed }
                else if offset > edit.location { result -= offset - edit.location }
            }
            return result
        }
        let start = adjusted(selection.location)
        let end = adjusted(NSMaxRange(selection))
        insertText(replacement, replacementRange: block)
        setSelectedRange(NSRange(location: start, length: max(0, end - start)))
    }

    func revealSelection(_ range: NSRange?, requestID: UUID?) {
        guard let range, let requestID, requestID != lastSelectionRequestID,
              range.location <= (string as NSString).length,
              range.length <= (string as NSString).length - range.location else { return }
        lastSelectionRequestID = requestID
        setSelectedRange(range)
        scrollRangeToVisible(range)
        window?.makeFirstResponder(self)
    }
    var onTextChange: (String) -> Void = { _ in }

    // Keep AppKit's designated initializers inherited. Its frame-only
    // initializer builds and owns the text system, then dynamically calls
    // init(frame:textContainer:); a new Swift designated init would hide it.
    convenience init() {
        self.init(frame: .zero)
        isRichText = false
        importsGraphics = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        alignment = .left
        textColor = .textColor
        insertionPointColor = .textColor
        backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: 8, height: 8)
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        delegate = self
        setAccessibilityIdentifier("clipy.workflow.source")
        configureLiteralInput()
    }

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
