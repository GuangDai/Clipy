/// Public per-format revision decisions through real History and AppKit.
/// This exercises neither ReviseEditorDraft nor the editor UI: their default
/// Keep Current decision is covered by the draft's owner tests. Here a native
/// rich-text consumer chooses its own format from the resulting pasteboard.
import AppKit
import Foundation
import HistoryCore
import PasteboardAdapter
import Testing

struct RichTextRevisionConsumerTests {
    @Test @MainActor
    func keepingThenHidingRTFChangesWhatTheNativeRichTextConsumerReads() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let source = ComposedSupport.makePasteboard()
        let destination = ComposedSupport.makePasteboard()
        defer {
            source.releaseGlobally()
            destination.releaseGlobally()
        }
        let originalText = Data("Before".utf8)
        let originalRTF = Data("{\\rtf1\\ansi Before}".utf8)
        let editedText = Data("After".utf8)
        let sourceItem = NSPasteboardItem()
        try #require(sourceItem.setData(originalText, forType: .string))
        try #require(sourceItem.setData(originalRTF, forType: .rtf))
        source.clearContents()
        try #require(source.writeObjects([sourceItem]))

        let capture = try #require(PasteboardAdapter(pasteboard: source).capture(
            observedAt: Date(timeIntervalSinceReferenceDate: 710_200_000)
        ))
        #expect(Set(capture.representations) == Set([
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: originalText),
            CapturedRepresentation(typeIdentifier: "public.rtf", bytes: originalRTF),
        ]))
        let insertion = try await history.perform(.capture(capture))
        let inserted = try #require(ComposedSupport.insertedReference(
            from: insertion, "rich-text consumer fixture"
        ))

        // Replace only UTF-8. Keeping the current, still-canonical RTF is an
        // explicit inheritCanonical decision, not cross-format conversion.
        let firstReceipt = try await history.perform(.revise(RevisionRequest(
            itemID: inserted.id,
            expected: inserted.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: "public.rtf", action: .inheritCanonical),
                RevisionDecision(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: editedText)),
            ]))
        )))
        let revised = try #require(ComposedSupport.revisedReference(
            from: firstReceipt, "UTF-8 replacement with current RTF retained"
        ))
        let firstPayload = try await history.pastePayload(for: inserted.id)
        #expect(firstPayload.item == revised)
        #expect(firstPayload.representations.first(where: {
            $0.typeIdentifier == "public.utf8-plain-text"
        })?.bytes == editedText)
        #expect(firstPayload.representations.first(where: {
            $0.typeIdentifier == "public.rtf"
        })?.bytes == originalRTF)
        try PasteboardAdapter(pasteboard: destination).write(firstPayload)
        let mixed = try #require(destination.pasteboardItems?.first)
        #expect(mixed.data(forType: .string) == editedText)
        #expect(mixed.data(forType: .rtf) == originalRTF)

        let richConsumer = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        richConsumer.isRichText = true
        let availableTypes = try #require(destination.types)
        #expect(richConsumer.preferredPasteboardType(
            from: availableTypes, restrictedToTypesFrom: nil
        ) == .rtf)
        // Do not force readSelection(from:type:): readSelection(from:) must
        // run AppKit's real preferred-type selection before native decoding.
        try #require(richConsumer.readSelection(from: destination))
        #expect(richConsumer.string == "Before")

        // Hide RTF while preserving the already-edited UTF-8 bytes. Restoring
        // UTF-8 from Canonical here would incorrectly bring back Before.
        let secondReceipt = try await history.perform(.revise(RevisionRequest(
            itemID: revised.id,
            expected: revised.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: "public.rtf", action: .hide),
                RevisionDecision(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: editedText)),
            ]))
        )))
        let plainOnly = try #require(ComposedSupport.revisedReference(
            from: secondReceipt, "RTF hidden with edited UTF-8 preserved"
        ))
        let secondPayload = try await history.pastePayload(for: inserted.id)
        #expect(secondPayload.item == plainOnly)
        #expect(secondPayload.representations.map(\.typeIdentifier) == ["public.utf8-plain-text"])
        #expect(secondPayload.representations.map(\.bytes) == [editedText])
        try PasteboardAdapter(pasteboard: destination).write(secondPayload)
        let plain = try #require(destination.pasteboardItems?.first)
        #expect(!plain.types.contains(.rtf))
        #expect(plain.data(forType: .string) == editedText)

        let freshConsumer = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        freshConsumer.isRichText = true
        try #require(freshConsumer.readSelection(from: destination))
        #expect(freshConsumer.string == "After")
        let details = try await history.details(for: inserted.id)
        #expect(details.item == plainOnly)
        #expect(details.canonical.first(where: {
            $0.typeIdentifier == "public.utf8-plain-text"
        })?.bytes == originalText)
        #expect(details.canonical.first(where: {
            $0.typeIdentifier == "public.rtf"
        })?.bytes == originalRTF)
        #expect(details.revisions.count == 2)
    }
}
