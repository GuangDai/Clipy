/// PreviewContentTests — the preview column's content resolution rules
/// (image-first, frozen textual UTI set, per-encoding decode, the long-body
/// cap) as pure-function proofs over `HistoryRepresentation` values.
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

    @Test func utf16PlainTextDecodesAsUTF16NeverAsUTF8() {
        let text = "utf16 body"
        let content = PreviewContent.resolve(effective: [
            representation("public.utf16-plain-text", text.data(using: .utf16)!),
        ])
        #expect(content == .text(text))
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
