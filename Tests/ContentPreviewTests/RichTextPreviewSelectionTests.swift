import Foundation
import Testing
@testable import ContentPreview

struct RichTextPreviewSelectionTests {
    @Test func exactPlainTextRemainsPreferredToRichRepresentations() async throws {
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.html", bytes: Data("<p>HTML</p>".utf8)),
            PreviewRepresentation(typeIdentifier: "public.rtf", bytes: Data("{\\rtf1 RTF}".utf8)),
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("literal <b>text</b>".utf8)),
        ])
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected the exact plain representation")
            return
        }
        #expect(text.text == "literal <b>text</b>")
        #expect(!text.wasTruncated)
    }

    @Test func rtfAndHTMLAreReachableThroughTheHistoryPane() async {
        let renderer = ContentPreview()
        let html = PreviewRepresentation(typeIdentifier: "public.html", bytes: Data("<p>HTML</p>".utf8))
        let rtf = PreviewRepresentation(typeIdentifier: "public.rtf", bytes: Data("{\\rtf1 RTF}".utf8))
        #expect(await renderer.renderHistoryPane([html]) == .content(.text(PreviewText(text: "HTML", wasTruncated: false))))
        #expect(await renderer.renderHistoryPane([rtf]) == .content(.text(PreviewText(text: "RTF", wasTruncated: false))))
        #expect(await renderer.renderHistoryPane([html, rtf]) == .content(.text(PreviewText(text: "RTF", wasTruncated: false))))
    }

    @Test(arguments: ["public.rtf", "public.html"])
    func oversizedRichInputUsesTheSelectedParserLimit(type: String) async {
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: type, bytes: Data(repeating: 0x61, count: 1_048_577)),
        ])
        #expect(outcome == .failed(.resourceLimit))
    }

    @Test func lookalikeRichIdentifiersRemainOpaque() async {
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.html.private", bytes: Data("<p>opaque</p>".utf8)),
            PreviewRepresentation(typeIdentifier: "public.rtf.private", bytes: Data("{\\rtf1 opaque}".utf8)),
        ])
        #expect(outcome == .unavailable(.unsupported))
    }

    @Test func malformedSelectedRTFDoesNotFallThroughToHTML() async {
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.html", bytes: Data("<p>alternate</p>".utf8)),
            PreviewRepresentation(typeIdentifier: "public.rtf", bytes: Data("not an RTF document".utf8)),
        ])
        #expect(outcome == .failed(.malformedRepresentation))
    }
}
