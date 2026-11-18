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
    func candidateViewportTracksNativeGeometryAndOnlyVisibleCandidatesOwnKeys() async throws {
        let (panel, field) = makePanel()
        defer { panel.close() }
        let content = try #require(panel.contentView)
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - 420,
                              width: panel.frame.width, height: 420), display: true)
        field.frame.origin.y = content.bounds.maxY - field.frame.height - 12
        field.autoresizingMask = [.minYMargin]
        let completion = HistorySearchCompletionState()
        var available: CGFloat?
        var submissions = 0
        field.onFocusChange = { completion.setFocused($0) }
        field.onInputChange = { completion.update($0) }
        field.onCompletionCommand = { completion.command($0) }
        field.onAvailableHeightChange = {
            available = $0
            completion.setAvailableHeight(Double($0))
        }
        field.onSubmit = { submissions += 1 }
        field.update(text: "", isFocused: true)
        let editor = try #require(field.currentEditor() as? NSTextView)
        let draft = "$ty"
        editor.insertText(draft, replacementRange: NSRange(location: 0, length: 0))
        try #require(await ComposedSupport.waitFor { completion.candidates.first?.id == "type:" && completion.isPresented })
        let before = try #require(available)
        let changedFrame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - 220,
                                  width: panel.frame.width, height: 220)
        panel.setFrame(changedFrame, display: true)
        let expected = max(0, field.convert(field.bounds, to: content).minY - content.bounds.minY - 8)
        try #require(expected < before)
        try #require(await ComposedSupport.waitFor { available == expected })

        // Resize notifications and editor updates share one actor turn. The
        // next report must use the final native viewport, not an earlier frame.
        let heights: [CGFloat] = [360, 180, 300]
        for height in heights {
            panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - height,
                                  width: panel.frame.width, height: height), display: true)
            field.update(text: draft, isFocused: true)
        }
        let finalExpected = max(0, field.convert(field.bounds, to: content).minY - content.bounds.minY - 8)
        try #require(finalExpected != expected)
        try #require(await ComposedSupport.waitFor { available == finalExpected })

        // More chrome above the field can leave room for part of the popup,
        // but no candidate row. Move the field and resize without editing.
        field.autoresizingMask = []
        field.frame.origin.y = content.bounds.minY + 9
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - 280,
                              width: panel.frame.width, height: 280), display: true)
        try #require(await ComposedSupport.waitFor { available == 1 })
        #expect(!completion.isPresented)
        #expect(!completion.consumesPanelCommands)
        #expect(!field.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(submissions == 1)
        #expect(editor.string == draft)
        #expect(completion.candidates.first?.id == "type:")
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.complete(_:))))
        #expect(!completion.isPresented)

        field.frame.origin.y = content.bounds.maxY - field.frame.height - 12
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - 300,
                              width: panel.frame.width, height: 300), display: true)
        try #require(await ComposedSupport.waitFor { completion.isPresented })
        #expect(completion.consumesPanelCommands)
        #expect(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(editor.string == "$type:$")
        #expect(submissions == 1)
    }

    @Test
    func longCompletionScrollsItsCaretAndNativeArrowsContinueEditingAfterRefresh() throws {
        let (panel, field) = makePanel()
        defer { panel.close() }
        field.frame.size.width = 125
        field.update(text: "$source-id:com.apple.Saf", isFocused: true)
        let editor = try #require(field.currentEditor() as? NSTextView)
        let expression = "$source-id:\"com.apple.Safari\"$"
        let insertion = HistorySearchCompletionInsertion(
            id: 1, originalText: editor.string,
            replacementRange: NSRange(location: 0, length: (editor.string as NSString).length),
            text: expression, selectionOffset: nil
        )
        try #require(field.applyCompletion(insertion))
        let end = (expression as NSString).length
        #expect(editor.selectedRange() == NSRange(location: end, length: 0))
        field.update(text: expression, isFocused: true)
        #expect(field.currentEditor() === editor)
        let caretScreen = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        let caretWindow = panel.convertFromScreen(caretScreen)
        let caretField = field.convert(caretWindow, from: nil)
        #expect(caretField.minX >= field.bounds.minX - 1)
        #expect(caretField.maxX <= field.bounds.maxX + 1)
        editor.moveLeft(nil)
        #expect(editor.selectedRange().location == end - 1)
        editor.moveRight(nil)
        #expect(editor.selectedRange().location == end)
        editor.insertText(" retained", replacementRange: editor.selectedRange())
        #expect(editor.string == expression + " retained")
    }

    @Test
    func markedTextKeepsItsEditorAndOwnsNavigationAndConfirmation() throws {
        let (panel, field) = makePanel()
        defer { panel.close() }
        var moves: [Int] = []
        var submits = 0
        var publishedSearches: [String] = []
        field.onMoveSelection = { moves.append($0) }
        field.onSubmit = { submits += 1 }
        field.onTextChange = { publishedSearches.append($0) }
        field.update(text: "", isFocused: true)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText(
            "ni", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        try #require(editor.hasMarkedText())
        let change = Notification(name: NSControl.textDidChangeNotification, object: field)
        field.controlTextDidChange(change)
        #expect(publishedSearches.isEmpty)
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
        editor.insertText("你", replacementRange: editor.markedRange())
        try #require(!editor.hasMarkedText())
        field.controlTextDidChange(change)
        #expect(publishedSearches.last == "你")
        #expect(!publishedSearches.contains("ni"))
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
