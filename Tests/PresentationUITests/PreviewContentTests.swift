/// PreviewContentTests — the preview column's content resolution rules
/// (image-first, exact text codec admission, structured sibling selection,
/// the long-body cap) as pure-function proofs over `HistoryRepresentation`.
import Foundation
import HistoryCore
import PresentationUI
import Testing

struct PreviewContentTests {

    private func representation(_ typeIdentifier: String, _ bytes: Data) -> HistoryRepresentation {
        HistoryRepresentation(typeIdentifier: typeIdentifier, bytes: bytes)
    }

    @Test func imageRepresentationWinsOverText() {
        let content = PreviewContent.resolve(effective: [
            representation("public.utf8-plain-text", Data("hello".utf8)),
            representation("public.png", Data([0x89, 0x50, 0x4E, 0x47])),
        ])
        guard case .image(let bytes) = content else {
            Issue.record("expected .image, got \(content)")
            return
        }
        #expect(bytes == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func utf8PlainTextResolvesToText() {
        let content = PreviewContent.resolve(effective: [
            representation("public.utf8-plain-text", Data("hello preview".utf8)),
        ])
        #expect(content == .text("hello preview"))
    }

    /// RTF bytes are an opaque structured representation at this preview
    /// seam. An exact UTF-8 plain-text sibling is the semantic body.
    @Test func rtfUsesExactUTF8PlainTextSibling() {
        let content = PreviewContent.resolve(effective: [
            representation(
                "public.rtf",
                Data(#"{\rtf1\ansi Rich \b text\b0}"#.utf8)
            ),
            representation(
                "public.utf8-plain-text",
                Data("Rich text".utf8)
            ),
        ])
        #expect(content == .text("Rich text"))
    }

    /// HTML is not displayed as UTF-8 source. Its exact plain sibling wins
    /// regardless of the structured representation's ordering.
    @Test func htmlUsesExactUTF8PlainTextSibling() {
        let content = PreviewContent.resolve(effective: [
            representation(
                "public.html",
                Data("<p>Hello <strong>preview</strong></p>".utf8)
            ),
            representation(
                "public.utf8-plain-text",
                Data("Hello preview".utf8)
            ),
        ])
        #expect(content == .text("Hello preview"))
    }

    /// Structured and encoding-unspecified text stays opaque until its own
    /// bounded semantic renderer or explicit codec is approved.
    @Test func textWithoutAnExactCodecIsUnavailable() {
        let fixtures = [
            representation(
                "public.rtf",
                Data(#"{\rtf1\ansi Literal RTF}"#.utf8)
            ),
            representation(
                "public.html",
                Data("<p>Literal HTML</p>".utf8)
            ),
            representation("public.text", Data("abstract text".utf8)),
            representation("public.plain-text", Data("unspecified encoding".utf8)),
        ]

        for fixture in fixtures {
            #expect(PreviewContent.resolve(effective: [fixture]) == .unavailable)
        }
    }

    /// macOS arm64 native UTF-16 is little-endian. The UTI permits a missing
    /// BOM, so the decoder cannot delegate that case to Foundation's generic
    /// UTF-16 default (which interprets an unspecified order as big-endian).
    @Test func nativeUTF16WithoutBOMDecodesAsLittleEndian() {
        let content = PreviewContent.resolve(effective: [
            representation(
                "public.utf16-plain-text",
                Data([0x41, 0x00, 0xA9, 0x03]) // "AΩ", literal UTF-16LE
            ),
        ])
        #expect(content == .text("AΩ"))
    }

    /// An explicit BOM controls the representation's byte order and is not
    /// exposed as preview text.
    @Test func utf16BOMControlsByteOrder() {
        let content = PreviewContent.resolve(effective: [
            representation(
                "public.utf16-plain-text",
                Data([0xFE, 0xFF, 0x00, 0x41, 0x03, 0xA9]) // "AΩ", UTF-16BE
            ),
        ])
        #expect(content == .text("AΩ"))
    }

    @Test func malformedCodecCandidateDoesNotHideLaterValidPlainText() {
        let content = PreviewContent.resolve(effective: [
            representation(
                "public.utf16-plain-text",
                Data([0x41])
            ),
            representation(
                "public.utf8-plain-text",
                Data("valid sibling".utf8)
            ),
        ])

        #expect(content == .text("valid sibling"))
    }

    @Test func longBodyIsCappedWithAMarker() {
        let body = String(repeating: "a", count: PreviewContent.textCharacterCap + 1_000)
        let content = PreviewContent.resolve(effective: [
            representation("public.utf8-plain-text", Data(body.utf8)),
        ])
        guard case .text(let preview) = content else {
            Issue.record("expected .text, got \(content)")
            return
        }
        #expect(preview.hasPrefix(String(repeating: "a", count: PreviewContent.textCharacterCap)))
        #expect(preview.hasSuffix("…"))
        #expect(preview.count < body.count)
    }

    @Test func nonPreviewableRepresentationsResolveToUnavailable() {
        let content = PreviewContent.resolve(effective: [
            representation("public.url", Data("https://example.com".utf8)),
        ])
        #expect(content == .unavailable)
    }

    @Test func emptyRepresentationsResolveToUnavailable() {
        #expect(PreviewContent.resolve(effective: []) == .unavailable)
    }
}
