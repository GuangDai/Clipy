/// The panel's native search input (V2-11). A retained NavigationStack root
/// can reject SwiftUI FocusState requests without calling makeFirstResponder.
/// Keep the actual NSTextField here so Back and Clear apply their existing
/// focus intent directly, without scheduling retries or searching a view tree.
import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let accessibilityLabel: String
    let onMoveSelection: (Int) -> Void
    let onSubmit: () -> Void
    var completion: HistorySearchCompletionState? = nil

    func makeNSView(context: Context) -> HistorySearchTextField {
        HistorySearchTextField()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HistorySearchTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: max(0, width), height: nsView.intrinsicContentSize.height)
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
            completion?.setFocused(focused)
        }
        field.onMoveSelection = onMoveSelection
        field.onSubmit = onSubmit
        field.onInputChange = { completion?.update($0) }
        field.onCompletionCommand = { completion?.command($0) ?? .unhandled }
        field.onAvailableHeightChange = { completion?.setAvailableHeight(Double($0)) }
        field.update(text: text, isFocused: isFocused)
        if let insertion = completion?.insertion { field.applyCompletion(insertion) }
    }
}

@MainActor
final class HistorySearchTextField: NSTextField, NSTextFieldDelegate {
    var onTextChange: (String) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    var onMoveSelection: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onInputChange: (HistorySearchCompletionInput) -> Void = { _ in }
    var onCompletionCommand: (HistorySearchCompletionCommand) -> HistorySearchCompletionDecision = { _ in .unhandled }
    var onAvailableHeightChange: (CGFloat) -> Void = { _ in }
    private var wantsFocus = false
    private weak var observedEditor: NSTextView?
    private weak var observedWindow: NSWindow?
    private var availableHeightTask: Task<Void, Never>?
    private var textRevision = 0
    private var reportedRevision = -1
    private var reportedSelection = NSRange(location: NSNotFound, length: 0)
    private var reportedComposition = false
    private var appliedInsertionID: Int?

    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        cell?.isScrollable = true
        font = .systemFont(ofSize: NSFont.systemFontSize)
        focusRingType = .none
        delegate = self
        setAccessibilityIdentifier("clipy.search.field")
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        // Query length must not enlarge the native view beyond SwiftUI's
        // search row. AppKit scrolls the editor inside this bounded viewport.
        NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
    }

    override func layout() {
        super.layout()
        scheduleAvailableHeightReport()
    }

    func update(text: String, isFocused: Bool) {
        // SwiftUI updates during composition must not replace the field
        // editor's marked text or insertion/selection range.
        if !stringValue.utf8.elementsEqual(text.utf8),
           !((currentEditor() as? NSTextView)?.hasMarkedText() ?? false) {
            stringValue = text
            textRevision += 1
        }
        wantsFocus = isFocused
        applyFocus()
        reportInput()
        scheduleAvailableHeightReport()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if observedWindow !== window {
            if let observedWindow {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: observedWindow)
            }
            observedWindow = window
            if let window {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowResized(_:)),
                    name: NSWindow.didResizeNotification, object: window
                )
            }
        }
        applyFocus()
        if window == nil {
            availableHeightTask?.cancel()
            availableHeightTask = nil
            stopObservingEditor()
            onFocusChange(false)
        } else {
            scheduleAvailableHeightReport()
        }
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
            if observedEditor !== editor {
                stopObservingEditor()
                observedEditor = editor
                NotificationCenter.default.addObserver(
                    self, selector: #selector(editorSelectionChanged(_:)),
                    name: NSTextView.didChangeSelectionNotification, object: editor
                )
            }
        }
        wantsFocus = true
        onFocusChange(true)
        reportInput()
        scheduleAvailableHeightReport()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        wantsFocus = false
        stopObservingEditor()
        onFocusChange(false)
    }

    func controlTextDidChange(_ notification: Notification) {
        textRevision += 1
        onTextChange(stringValue)
        reportInput()
    }

    @objc private func editorSelectionChanged(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, editor === observedEditor else { return }
        reportInput()
    }

    private func stopObservingEditor() {
        if let observedEditor {
            NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: observedEditor)
        }
        observedEditor = nil
        reportedRevision = -1
        reportedSelection = NSRange(location: NSNotFound, length: 0)
    }

    private func reportInput() {
        guard let editor = currentEditor() as? NSTextView,
              window?.firstResponder === editor else { return }
        let selection = editor.selectedRange()
        let isComposing = editor.hasMarkedText()
        guard textRevision != reportedRevision || selection != reportedSelection || isComposing != reportedComposition else { return }
        reportedRevision = textRevision
        reportedSelection = selection
        reportedComposition = isComposing
        onInputChange(HistorySearchCompletionInput(text: editor.string, selection: selection, isComposing: isComposing))
    }

    @objc private func windowResized(_ notification: Notification) {
        scheduleAvailableHeightReport()
    }

    private func scheduleAvailableHeightReport() {
        guard availableHeightTask == nil else { return }
        availableHeightTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            defer {
                if !Task.isCancelled { self.availableHeightTask = nil }
            }
            // The window resizes after SwiftUI has updated the query. Read
            // native coordinates on the next actor turn after layout, even
            // when only ancestors move and the field's own size is unchanged.
            self.window?.contentView?.layoutSubtreeIfNeeded()
            guard !Task.isCancelled else { return }
            self.reportAvailableHeight()
        }
    }

    private func reportAvailableHeight() {
        guard let content = window?.contentView else { return }
        let field = convert(bounds, to: content)
        let available = content.isFlipped ? content.bounds.maxY - field.maxY : field.minY - content.bounds.minY
        onAvailableHeightChange(max(0, available - 8))
    }

    @discardableResult
    func applyCompletion(_ insertion: HistorySearchCompletionInsertion) -> Bool {
        guard appliedInsertionID != insertion.id,
              let editor = currentEditor() as? NSTextView,
              window?.firstResponder === editor, !editor.hasMarkedText(),
              editor.string.utf8.elementsEqual(insertion.originalText.utf8) else { return false }
        let length = (editor.string as NSString).length
        guard insertion.replacementRange.location <= length,
              insertion.replacementRange.length <= length - insertion.replacementRange.location else { return false }
        appliedInsertionID = insertion.id
        editor.insertText(insertion.text, replacementRange: insertion.replacementRange)
        let offset = insertion.selectionOffset ?? (insertion.text as NSString).length
        editor.setSelectedRange(NSRange(location: insertion.replacementRange.location + offset, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        textRevision += 1
        onTextChange(editor.string)
        reportInput()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Space), event.modifierFlags.intersection([.command, .control, .option, .shift]) == .control,
           let editor = currentEditor() as? NSTextView, !editor.hasMarkedText() {
            reportInput()
            if handleCompletion(.request) { return }
        }
        super.keyDown(with: event)
    }

    private func handleCompletion(_ command: HistorySearchCompletionCommand) -> Bool {
        switch onCompletionCommand(command) {
        case .unhandled: return false
        case .handled: return true
        case .insert(let insertion): return applyCompletion(insertion)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Candidate navigation and confirmation belong to the input method.
        // FloatingPanel separately preserves marked Return/Escape dispatch.
        guard !textView.hasMarkedText() else { return false }
        reportInput()
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            if handleCompletion(.next) { return true }
            onMoveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            if handleCompletion(.previous) { return true }
            onMoveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)):
            if handleCompletion(.accept) { return true }
            onSubmit()
        case #selector(NSResponder.insertTab(_:)):
            return handleCompletion(.accept)
        case #selector(NSResponder.cancelOperation(_:)):
            return handleCompletion(.dismiss)
        case #selector(NSResponder.complete(_:)):
            return handleCompletion(.request)
        default:
            return false
        }
        return true
    }
}
