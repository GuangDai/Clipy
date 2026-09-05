/// Public per-format revision decisions through real History and AppKit.
/// This exercises neither ReviseEditorDraft nor the editor UI: their default
/// Keep Current decision is covered by the draft's owner tests. Here a native
/// rich-text consumer chooses its own format from the resulting pasteboard.
/// AppKit also synthesizes external UTF-16; both old siblings must explicitly
/// be hidden before the only retained representation contains the edited text.
import AppKit
import Foundation
import HistoryCore
import PasteboardAdapter
import Testing

struct RichTextRevisionConsumerTests {
    @Test @MainActor
    func keepingThenHidingOldSiblingsChangesWhatTheNativeRichTextConsumerReads() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let source = ComposedSupport.makePasteboard()
        let destination = ComposedSupport.makePasteboard()
        defer {
            source.releaseGlobally()
            destination.releaseGlobally()
        }
        let originalText = Data("Before".utf8)
        let originalRTF = Data("{\\rtf1\\ansi Before}".utf8)
        let utf16Identifier = "public.utf16-external-plain-text"
        let utf16Type = NSPasteboard.PasteboardType(utf16Identifier)
        let editedText = Data("After".utf8)
        let sourceItem = NSPasteboardItem()
        try #require(sourceItem.setData(originalText, forType: .string))
        try #require(sourceItem.setData(originalRTF, forType: .rtf))
        source.clearContents()
        try #require(source.writeObjects([sourceItem]))

        let capture = try #require(PasteboardAdapter(pasteboard: source).capture(
            observedAt: Date(timeIntervalSinceReferenceDate: 710_200_000)
        ))
        let originalUTF16 = try #require(capture.representations.first(where: {
            $0.typeIdentifier == utf16Identifier
        })?.bytes)
        #expect(originalUTF16.count == 14)
        #expect(originalUTF16.starts(with: [0xFE, 0xFF])
            || originalUTF16.starts(with: [0xFF, 0xFE]))
        #expect(String(data: originalUTF16, encoding: .utf16) == "Before")
        #expect(source.pasteboardItems?.first?.data(forType: utf16Type) == originalUTF16)
        #expect(Set(capture.representations) == Set([
            CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: originalText),
            CapturedRepresentation(typeIdentifier: "public.rtf", bytes: originalRTF),
            CapturedRepresentation(typeIdentifier: utf16Identifier, bytes: originalUTF16),
        ]))
        let insertion = try await history.perform(.capture(capture))
        let inserted = try #require(ComposedSupport.insertedReference(
            from: insertion, "rich-text consumer fixture"
        ))

        // Replace only UTF-8. Keeping the still-canonical RTF and synthesized
        // UTF-16 uses explicit decisions, not filtering or format conversion.
        let firstReceipt = try await history.perform(.revise(RevisionRequest(
            itemID: inserted.id,
            expected: inserted.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: "public.rtf", action: .inheritCanonical),
                RevisionDecision(typeIdentifier: utf16Identifier, action: .inheritCanonical),
                RevisionDecision(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: editedText)),
            ]))
        )))
        let revised = try #require(ComposedSupport.revisedReference(
            from: firstReceipt, "UTF-8 replacement with current RTF and UTF-16 retained"
        ))
        let firstPayload = try await history.pastePayload(for: inserted.id)
        #expect(firstPayload.item == revised)
        #expect(firstPayload.representations.first(where: {
            $0.typeIdentifier == "public.utf8-plain-text"
        })?.bytes == editedText)
        #expect(firstPayload.representations.first(where: {
            $0.typeIdentifier == "public.rtf"
        })?.bytes == originalRTF)
        #expect(firstPayload.representations.first(where: {
            $0.typeIdentifier == utf16Identifier
        })?.bytes == originalUTF16)
        try PasteboardAdapter(pasteboard: destination).write(firstPayload)
        let mixed = try #require(destination.pasteboardItems?.first)
        #expect(mixed.data(forType: .string) == editedText)
        #expect(mixed.data(forType: .rtf) == originalRTF)
        #expect(mixed.data(forType: utf16Type) == originalUTF16)

        let richConsumer = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        richConsumer.isRichText = true
        let availableTypes = try #require(destination.types)
        let preferred = try #require(richConsumer.preferredPasteboardType(
            from: availableTypes, restrictedToTypesFrom: nil
        ))
        // NSTextView's native API can name RTF with its legacy pasteboard
        // spelling. That API vocabulary is distinct from History's captured
        // public.rtf identifier; neither accepted value admits plain text.
        #expect([
            "public.rtf",
            "NeXT Rich Text Format v1.0 pasteboard type",
        ].contains(preferred.rawValue))
        // Do not force readSelection(from:type:): readSelection(from:) must
        // run AppKit's real preferred-type selection before native decoding.
        try #require(richConsumer.readSelection(from: destination))
        #expect(richConsumer.string == "Before")

        // Hide both old siblings while preserving the edited UTF-8 bytes.
        // Restoring UTF-8 from Canonical would incorrectly bring back Before.
        let secondReceipt = try await history.perform(.revise(RevisionRequest(
            itemID: revised.id,
            expected: revised.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: "public.rtf", action: .hide),
                RevisionDecision(typeIdentifier: utf16Identifier, action: .hide),
                RevisionDecision(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: editedText)),
            ]))
        )))
        let plainOnly = try #require(ComposedSupport.revisedReference(
            from: secondReceipt, "RTF and UTF-16 hidden with edited UTF-8 preserved"
        ))
        let secondPayload = try await history.pastePayload(for: inserted.id)
        #expect(secondPayload.item == plainOnly)
        #expect(secondPayload.representations.map(\.typeIdentifier) == ["public.utf8-plain-text"])
        #expect(secondPayload.representations.map(\.bytes) == [editedText])
        try PasteboardAdapter(pasteboard: destination).write(secondPayload)
        let plain = try #require(destination.pasteboardItems?.first)
        #expect(!plain.types.contains(.rtf))
        #expect(plain.data(forType: .string) == editedText)
        // If AppKit synthesizes UTF-16 again, it must derive from After;
        // History has omitted the captured Before bytes from this payload.
        if plain.types.contains(utf16Type) {
            let regenerated = try #require(plain.data(forType: utf16Type))
            #expect(String(data: regenerated, encoding: .utf16) == "After")
            #expect(regenerated != originalUTF16)
        }

        let freshConsumer = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        freshConsumer.isRichText = true
        try #require(freshConsumer.readSelection(from: destination))
        #expect(freshConsumer.string == "After")
        let details = try await history.details(for: inserted.id)
        #expect(details.item == plainOnly)
        #expect(Set(details.canonical.map {
            CapturedRepresentation(typeIdentifier: $0.typeIdentifier, bytes: $0.bytes)
        }) == Set(capture.representations))
        #expect(details.revisions.count == 2)
    }
}
