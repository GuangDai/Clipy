import ContentPreview
import Foundation
import Testing

struct TextPreviewBoundaryTests {
    @Test(arguments: ["\u{FEFF}", "\u{FEFF}B🦊", "\u{FEFF}\u{FEFF}B🦊"])
    func utf8ContentMarkersRemainSelectableSourceText(source: String) async {
        let bytes = Data(source.utf8)
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: bytes),
        ])
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected UTF-8 text preserving its content markers, got \(outcome)")
            return
        }
        #expect(Data(text.text.utf8) == bytes)
        #expect(!text.wasTruncated)
    }

    @Test func leadingUTF8ContentMarkerCountsTowardTheDisplayLimit() async {
        let prefix = "\u{FEFF}" + String(repeating: "x", count: 49_999)
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: "public.utf8-plain-text", bytes: Data((prefix + "y").utf8)
            ),
        ])
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected the exact capped UTF-8 source prefix, got \(outcome)")
            return
        }
        #expect(Data(text.text.utf8) == Data(prefix.utf8))
        #expect(text.wasTruncated)
    }

    @Test func leadingUTF8ContentMarkerDoesNotRepairMalformedText() async {
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data([0xEF, 0xBB, 0xBF, 0xC3, 0x28])
            ),
        ])
        #expect(outcome == .failed(.malformedRepresentation))
    }

    @Test(arguments: [49_999, 50_000, 50_001])
    func textAtTheDisplayLimitPreservesOnlyTheSourcePrefix(count: Int) async {
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
            #expect(Data(text.text.utf8) == Data(String(repeating: "x", count: 50_000).utf8))
        } else {
            #expect(!text.wasTruncated)
            #expect(Data(text.text.utf8) == Data(source.utf8))
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
        #expect(text.wasTruncated == !tail.isEmpty)
        // Byte equality additionally rejects normalization of combining text.
        #expect(Data(text.text.utf8) == Data(prefix.utf8))
    }

    @Test(arguments: [0, 49_997])
    func originalEllipsisSuffixIsNotATruncationNotice(prefixCount: Int) async {
        let source = String(repeating: "x", count: prefixCount) + "\n\n…"
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8)),
        ])
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected unmodified source text, got \(outcome)")
            return
        }
        #expect(!text.wasTruncated)
        #expect(Data(text.text.utf8) == Data(source.utf8))
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
