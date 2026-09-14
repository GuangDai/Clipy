import AppKit
import SwiftUI
import Testing
@testable import ClipyApp

@Suite("Literal workflow source editing", .serialized)
@MainActor
struct BuiltInAutomationSourceEditorHostedTests {
    @Test func emptySwiftUIEditorFillsViewportAndRetainsNativeViewWhileResizing() throws {
        var source = ""
        let view = BuiltInAutomationSourceEditor(text: Binding(get: { source }, set: { source = $0 }),
                                                accessibilityLabel: "Test text")
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(findScroll(in: host))
        scroll.tile()
        let editor = try #require(scroll.documentView as? BuiltInAutomationSourceTextView)
        #expect(editor.textStorage != nil)
        #expect(editor.layoutManager != nil)
        #expect(editor.textContainer != nil)
        #expect(editor.frame.width > 0)
        #expect(editor.frame.height >= scroll.contentSize.height)
        #expect(abs(editor.frame.width - scroll.contentSize.width) <= 1)
        try #require(window.makeFirstResponder(editor))

        let literal = String(repeating: "literal words to wrap ", count: 80)
        editor.insertText(literal, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(source == literal)
        window.setContentSize(NSSize(width: 190, height: 160))
        host.layoutSubtreeIfNeeded()
        scroll.tile()
        editor.layoutManager?.ensureLayout(for: try #require(editor.textContainer))
        #expect(scroll.documentView === editor)
        #expect(abs(editor.frame.width - scroll.contentSize.width) <= 1)
        #expect(editor.frame.height > scroll.contentSize.height)
        #expect(editor.string == literal)
        #expect(editor.textContainer?.widthTracksTextView == true)
        #expect(!scroll.hasHorizontalScroller)
    }

    @Test func focusDisablesInheritedSubstitutionsAndTypingPublishesExactBytes() throws {
        let editor = BuiltInAutomationSourceTextView()
        let window = makeWindow(editor: editor)
        defer { window.close() }
        try #require(window.makeFirstResponder(nil))
        // Simulate text-system preferences being enabled on this instance;
        // neither the test nor the product changes global user preferences.
        editor.isAutomaticTextReplacementEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = true
        editor.isAutomaticDashSubstitutionEnabled = true
        editor.isAutomaticSpellingCorrectionEnabled = true
        editor.isAutomaticTextCompletionEnabled = true
        editor.smartInsertDeleteEnabled = true
        try #require(window.makeFirstResponder(editor))
        #expect(!editor.isAutomaticTextReplacementEnabled)
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isAutomaticDashSubstitutionEnabled)
        #expect(!editor.isAutomaticSpellingCorrectionEnabled)
        #expect(!editor.isAutomaticTextCompletionEnabled)
        #expect(!editor.smartInsertDeleteEnabled)
        #expect(editor.enabledTextCheckingTypes == 0)

        var published = ""
        editor.onTextChange = { published = $0 }
        let literal = "  playground result  \n\"ASCII quotes\" -- ... e\u{301} 中文"
        for character in literal {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(Array(editor.string.utf8) == Array(literal.utf8))
        #expect(Array(published.utf8) == Array(literal.utf8))
        #expect(editor.accessibilityIdentifier() == "clipy.workflow.source")
    }

    @Test func bindingEchoPreservesSelectionUndoAndMarkedInput() throws {
        let editor = BuiltInAutomationSourceTextView()
        let window = makeWindow(editor: editor)
        defer { window.close() }
        try #require(window.makeFirstResponder(editor))
        editor.insertText("literal text", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setSelectedRange(NSRange(location: 3, length: 4))
        let undoBefore = editor.undoManager?.canUndo
        editor.update(text: "literal text")
        #expect(editor.selectedRange() == NSRange(location: 3, length: 4))
        #expect(editor.undoManager?.canUndo == undoBefore)

        editor.update(text: "é")
        editor.update(text: "e\u{301}")
        #expect(Array(editor.string.utf8) == Array("e\u{301}".utf8))
        editor.update(text: "")
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(editor.hasMarkedText())
        editor.update(text: "")
        #expect(editor.hasMarkedText())
        #expect(editor.string == "ni")
        editor.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "你")
    }

    private func makeWindow(editor: BuiltInAutomationSourceTextView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = BuiltInAutomationSourceScrollView()
        scroll.documentView = editor
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func findScroll(in view: NSView) -> BuiltInAutomationSourceScrollView? {
        if let scroll = view as? BuiltInAutomationSourceScrollView { return scroll }
        for child in view.subviews {
            if let scroll = findScroll(in: child) { return scroll }
        }
        return nil
    }
}
