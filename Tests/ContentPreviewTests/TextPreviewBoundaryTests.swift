import ContentPreview
import Foundation
import Testing

struct TextPreviewBoundaryTests {
    @Test(arguments: [49_999, 50_000, 50_001])
    func textAtTheDisplayLimitAddsAnEllipsisOnlyForOmittedContent(count: Int) async {
        let source = String(repeating: "x", count: count)
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8)),
        ])
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected a text preview, got \(outcome)")
            return
        }
        if count == 50_001 {
            #expect(text.wasTruncated)
            #expect(text.text == String(repeating: "x", count: 50_000) + "\n\n…")
        } else {
            #expect(!text.wasTruncated)
            #expect(text.text == source)
        }
    }

    @Test(arguments: ["", "omitted tail"])
    func composedEmojiAndCombiningMarksStayWholeAtTheBoundary(tail: String) async {
        // Each decomposed e+accent and the complete emoji is one Character.
        // UTF-16-unit or Unicode-scalar indexing would cut this at the wrong
        // place even though it contains exactly 50,000 display Characters.
        let prefix = String(repeating: "e\u{301}", count: 49_999) + "👩🏽‍💻"
        let source = prefix + tail
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8)),
        ])
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected a Unicode text preview, got \(outcome)")
            return
        }
        let expected = prefix + (tail.isEmpty ? "" : "\n\n…")
        #expect(text.wasTruncated == !tail.isEmpty)
        // Byte equality additionally rejects normalization of combining text.
        #expect(Data(text.text.utf8) == Data(expected.utf8))
    }

    @Test func emptyDeclaredTextKeepsItsExistingFailureOutcome() async {
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data()),
        ])
        #expect(outcome == .failed(.malformedRepresentation))
    }

    @Test func malformedBytesBeyondTheDisplayLimitStillRejectTheRepresentation() async {
        let bytes = Data(String(repeating: "x", count: 50_000).utf8) + Data([0xC3, 0x28])
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: bytes),
        ])
        #expect(outcome == .failed(.malformedRepresentation))
    }
}
