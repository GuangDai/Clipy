/// Native search-field evidence: actual field-editor ownership, immediate
/// focus reporting, exact query spelling and marked-text command ownership.
/// The running VisualLayout journey separately exercises NavigationStack Back.
import AppKit
import Testing
@testable import ClipyApp

@Suite("Hosted native history search", .serialized)
@MainActor
struct HistorySearchFieldHostedTests {
    @Test
    func focusIsReportedBeforeTypingAndCanReturnToTheRetainedField() throws {
        let (panel, field) = makePanel()
        defer { panel.close() }
        var focused = false
        var typed = ""
        field.onFocusChange = { focused = $0 }
        field.onTextChange = { typed = $0 }
        try #require(panel.makeFirstResponder(nil))

        // Clicking/Tab focus must disable bare Space shortcuts before the
        // first character; a text-did-begin notification alone is too late.
        try #require(panel.makeFirstResponder(field))
        #expect(focused)
        let firstEditor = try #require(field.currentEditor() as? NSTextView)
        #expect(panel.firstResponder === firstEditor)

        field.update(text: "", isFocused: false)
        #expect(!focused)
        #expect(field.currentEditor() == nil)
        field.update(text: "", isFocused: true)
        let returnedEditor = try #require(field.currentEditor() as? NSTextView)
        #expect(panel.firstResponder === returnedEditor)
        #expect(focused)

        let query = "Reading notes e\u{301}"
        returnedEditor.insertText(query, replacementRange: NSRange(location: 0, length: 0))
        #expect(Array(typed.utf8) == Array(query.utf8))
        returnedEditor.setSelectedRange(NSRange(location: 3, length: 4))
        field.update(text: query, isFocused: true)
        #expect(returnedEditor.selectedRange() == NSRange(location: 3, length: 4))

        field.update(text: "", isFocused: true)
        #expect(field.stringValue.isEmpty)
        #expect(field.currentEditor() === returnedEditor)
    }

    @Test
    func markedTextKeepsItsEditorAndOwnsNavigationAndConfirmation() throws {
        let (panel, field) = makePanel()
        defer { panel.close() }
        var moves: [Int] = []
        var submits = 0
        field.onMoveSelection = { moves.append($0) }
        field.onSubmit = { submits += 1 }
        field.update(text: "", isFocused: true)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try #require(editor.hasMarkedText())
        field.update(text: "", isFocused: true)
        #expect(editor.hasMarkedText())
        #expect(editor.string == "ni")
        for selector in [
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.cancelOperation(_:)),
        ] {
            #expect(!field.control(field, textView: editor, doCommandBy: selector))
        }
        #expect(moves.isEmpty)
        #expect(submits == 0)
        editor.unmarkText()
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!field.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(moves == [1, -1])
        #expect(submits == 1)
    }

    private func makePanel() -> (FloatingPanel, HistorySearchTextField) {
        let appDelegate = AppDelegate()
        let panel = FloatingPanel(
            rootView: PanelRootView(appDelegate: appDelegate),
            previewState: appDelegate.previewState,
            onClosed: {}
        )
        let field = HistorySearchTextField()
        field.frame = NSRect(x: 12, y: 12, width: 300, height: 24)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 48))
        content.addSubview(field)
        panel.contentView = content
        panel.open(at: .center, statusItemButtonScreenFrame: nil)
        return (panel, field)
    }
}
