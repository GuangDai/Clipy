import ContentPreview
import Foundation
import Testing

struct UTF16ContentMarkerPreviewTests {
    @Test(arguments: [
        ("public.utf16-plain-text", Data([0x41, 0x00]), "A"),
        ("public.utf16-external-plain-text", Data([0x00, 0x41]), "A"),
        ("public.utf16-plain-text", Data([0xFE, 0xFF, 0x00, 0x41]), "A"),
        ("public.utf16-external-plain-text", Data([0xFF, 0xFE, 0x41, 0x00]), "A"),
        ("public.utf16-plain-text", Data([0xFF, 0xFE, 0xFF, 0xFE, 0x41, 0x00]), "\u{FEFF}A"),
        ("public.utf16-plain-text", Data([0xFF, 0xFE, 0xFE, 0xFF, 0x41, 0x00]), "\u{FFFE}A"),
        ("public.utf16-external-plain-text", Data([0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x41]), "\u{FEFF}A"),
        ("public.utf16-external-plain-text", Data([0xFE, 0xFF, 0xFF, 0xFE, 0x00, 0x41]), "\u{FFFE}A"),
        ("public.utf16-plain-text", Data([0xFE, 0xFF, 0xFF, 0xFE, 0x00, 0x41]), "\u{FFFE}A"),
        ("public.utf16-external-plain-text", Data([0xFF, 0xFE, 0xFE, 0xFF, 0x41, 0x00]), "\u{FFFE}A"),
    ])
    func detailsSizedPreviewPreservesLiteralByteOrderAndContentMarkers(
        type: String, bytes: Data, expected: String
    ) async {
        let outcome = await renderDetailsExcerpt(type: type, bytes: bytes)
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected literal UTF-16 text, got \(outcome)")
            return
        }
        #expect(Data(text.text.utf8) == Data(expected.utf8))
        #expect(Data(text.displaySegments.joined().utf8) == Data(expected.utf8))
        #expect(!text.wasTruncated)
    }

    @Test(arguments: [
        ("public.utf16-plain-text", Data([0x00, 0xD8])),
        ("public.utf16-plain-text", Data([0x00, 0xDC])),
        ("public.utf16-plain-text", Data([0x00, 0xD8, 0x41, 0x00])),
        ("public.utf16-plain-text", Data([0xFF, 0xFE, 0x00, 0xD8])),
        ("public.utf16-plain-text", Data([0xFE, 0xFF, 0xDC, 0x00])),
        ("public.utf16-external-plain-text", Data([0xD8, 0x00])),
        ("public.utf16-external-plain-text", Data([0xDC, 0x00])),
        ("public.utf16-external-plain-text", Data([0xD8, 0x00, 0x00, 0x41])),
        ("public.utf16-external-plain-text", Data([0xFE, 0xFF, 0xDC, 0x00])),
        ("public.utf16-external-plain-text", Data([0xFF, 0xFE, 0x00, 0xD8])),
        ("public.utf16-plain-text", Data()),
        ("public.utf16-external-plain-text", Data()),
        ("public.utf16-plain-text", Data([0xFF, 0xFE])),
        ("public.utf16-external-plain-text", Data([0xFE, 0xFF])),
    ])
    func detailsSizedPreviewRejectsUnpairedSurrogatesAndEmptyText(type: String, bytes: Data) async {
        #expect(await renderDetailsExcerpt(type: type, bytes: bytes) == .failed(.malformedRepresentation))
    }

    @Test(arguments: ["public.utf16-plain-text", "public.utf16-external-plain-text"])
    func malformedUTF16BeyondFiveHundredCharactersStillRejectsTheWholeSource(type: String) async {
        let littleEndian = type == "public.utf16-plain-text"
        let prefix = Data(Array(repeating: littleEndian ? [UInt8(0x41), 0x00] : [UInt8(0x00), 0x41], count: 501).flatMap { $0 })
        let suffixes = littleEndian
            ? [Data([0x00, 0xD8]), Data([0x00, 0xDC]), Data([0x41])]
            : [Data([0xD8, 0x00]), Data([0xDC, 0x00]), Data([0x41])]
        for suffix in suffixes {
            #expect(await renderDetailsExcerpt(type: type, bytes: prefix + suffix)
                    == .failed(.malformedRepresentation))
        }
    }

    @Test func fiveHundredCharacterExcerptKeepsAndSegmentsItsEntireLastGrapheme() async throws {
        let expected = String(repeating: "A", count: 499) + "e" + String(repeating: "\u{301}", count: 20_000)
        let source = expected + "omitted tail"
        let bytes = try #require(source.data(using: .utf16BigEndian))
        let outcome = await renderDetailsExcerpt(type: "public.utf16-external-plain-text", bytes: bytes)
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected a segmented complete-grapheme excerpt, got \(outcome)")
            return
        }
        #expect(text.text.count == 500)
        #expect(text.wasTruncated)
        #expect(Data(text.text.utf8) == Data(expected.utf8))
        #expect(Data(text.displaySegments.joined().utf8) == Data(expected.utf8))
        #expect(text.displaySegments.first?.utf16.count == 499)
        #expect(text.displaySegments.dropFirst().allSatisfy { $0.utf16.count <= 64 })
    }

    private func renderDetailsExcerpt(type: String, bytes: Data) async -> PreviewOutcome {
        guard let source = ContentPreview.prepareHistoryPane([
            PreviewRepresentationMetadata(typeIdentifier: type, byteCount: bytes.count)
        ]).first else {
            Issue.record("Expected an exact UTF-16 source")
            return .unavailable(.unsupported)
        }
        return await ContentPreview().renderSelectedHistoryPane(
            source, representation: PreviewRepresentation(typeIdentifier: type, bytes: bytes),
            textConfiguration: .init(maximumCharacters: 500)
        )
    }

    @Test(arguments: [
        ("public.utf16-plain-text", Data([0xFF, 0xFE, 0xFF, 0xFE, 0x42, 0x00, 0x3E, 0xD8, 0x8A, 0xDD])),
        ("public.utf16-external-plain-text", Data([0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x42, 0xD8, 0x3E, 0xDD, 0x8A])),
    ])
    func onlyTheEncodingMarkerIsConsumed(type: String, bytes: Data) async {
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: type, bytes: bytes),
        ])
        guard case let .content(.text(text)) = outcome else {
            Issue.record("expected UTF-16 text retaining its content marker, got \(outcome)")
            return
        }
        // Literal UTF-8 for U+FEFF, B, U+1F98A. The second UTF-16 marker
        // is a content scalar, not another encoding signature to remove.
        #expect(Data(text.text.utf8) == Data([0xEF, 0xBB, 0xBF, 0x42, 0xF0, 0x9F, 0xA6, 0x8A]))
        #expect(text.text.count == 3)
        #expect(!text.wasTruncated)
    }
}
