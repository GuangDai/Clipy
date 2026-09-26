import AppKit
import Testing
@testable import ClipyApp

@MainActor
struct WorkflowSyntaxSourceHostedTests {
    @Test func ruleInputUsesSpacesAndContinuesBlockIndentation() throws {
        let editor = BuiltInAutomationSourceTextView()
        editor.usesRuleIndentation = true
        let window = makeWindow(editor: editor)
        defer { window.close() }
        try #require(window.makeFirstResponder(editor))
        editor.insertText("if is_text():", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertNewline(nil)
        editor.insertText("trim()", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertNewline(nil)
        #expect(editor.string == "if is_text():\n    trim()\n    ")
        editor.insertTab(nil)
        #expect(editor.string.hasSuffix("\n        "))
        #expect(!editor.string.contains("\t"))
    }

    @Test func errorSelectionIsAppliedOnceAndSelectsWholeUnicodeCharacters() throws {
        let editor = BuiltInAutomationSourceTextView()
        let window = makeWindow(editor: editor)
        defer { window.close() }
        editor.update(text: "trim()\r\n# 你😀e\u{301}")
        let range = WorkflowSyntaxLocation.selection(in: editor.string, line: 2, column: 5)
        let request = UUID()
        editor.revealSelection(range, requestID: request)
        #expect(editor.selectedRange() == range)
        #expect((editor.string as NSString).substring(with: range) == "e\u{301}")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.revealSelection(range, requestID: request)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        editor.revealSelection(range, requestID: UUID())
        #expect(editor.selectedRange() == range)
    }

    @Test func tabAndBacktabAdjustSelectedLinesWithoutChangingLiteralContents() throws {
        let editor = BuiltInAutomationSourceTextView()
        editor.usesRuleIndentation = true
        let window = makeWindow(editor: editor)
        defer { window.close() }
        try #require(window.makeFirstResponder(editor))
        let original = "replace(\"😀\", \"e\u{301}\")\ntrim()\nnotify()"
        editor.update(text: original)
        let finalLineStart = (original as NSString).range(of: "notify()").location
        editor.setSelectedRange(NSRange(location: 0, length: finalLineStart))
        editor.insertTab(nil)
        #expect(editor.string == "    replace(\"😀\", \"e\u{301}\")\n    trim()\nnotify()")
        editor.insertBacktab(nil)
        #expect(editor.string.utf8.elementsEqual(original.utf8))
        #expect(editor.selectedRange() == NSRange(location: 0, length: finalLineStart))

        editor.update(text: "    trim()")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.insertBacktab(nil)
        #expect(editor.string == "trim()")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
    }

    private func makeWindow(editor: BuiltInAutomationSourceTextView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = BuiltInAutomationSourceScrollView()
        scroll.documentView = editor
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
