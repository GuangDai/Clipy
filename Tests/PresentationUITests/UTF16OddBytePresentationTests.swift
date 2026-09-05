/// The same odd-byte UTF-16 payload crosses each concrete presentation
/// decoder; a valid prefix must not hide the incomplete final code unit.
import ContentPreview
import Foundation
import HistoryCore
import PresentationUI
import Testing

struct UTF16OddBytePresentationTests {
    struct Fixture: Sendable {
        let type: String
        let valid: Data
    }

    @Test(arguments: [
        Fixture(type: "public.utf16-plain-text", valid: Data([0x41, 0x00])),
        Fixture(type: "public.utf16-external-plain-text", valid: Data([0x00, 0x41])),
        Fixture(type: "public.utf16-plain-text", valid: Data([0xFF, 0xFE, 0x41, 0x00])),
        Fixture(type: "public.utf16-external-plain-text", valid: Data([0xFE, 0xFF, 0x00, 0x41])),
    ])
    func everyTextSurfaceRejectsAnIncompleteTrailingCodeUnit(_ fixture: Fixture) async throws {
        let valid = HistoryRepresentation(typeIdentifier: fixture.type, bytes: fixture.valid)
        let codec = try #require(EditorTextCodec.matching(valid))
        #expect(codec.decode(valid.bytes) == "A")
        #expect(DetailsRepresentationPresentation.resolve(valid) == .plainText("A"))
        let renderer = ContentPreview()
        let validPreview = await renderer.renderHistoryPane([
            PreviewRepresentation(typeIdentifier: fixture.type, bytes: fixture.valid),
        ])
        guard case .content(.text(let text)) = validPreview else {
            Issue.record("The complete UTF-16 control must render text")
            return
        }
        #expect(text.text == "A")

        let malformed = HistoryRepresentation(
            typeIdentifier: fixture.type, bytes: fixture.valid + Data([0xFF])
        )
        #expect(EditorTextCodec.matching(malformed) == nil)
        #expect(codec.decode(malformed.bytes) == nil)
        #expect(DetailsRepresentationPresentation.resolve(malformed) == .metadataOnly)
        let malformedPreview = await renderer.renderHistoryPane([
            PreviewRepresentation(typeIdentifier: fixture.type, bytes: malformed.bytes),
        ])
        #expect(malformedPreview == .failed(.malformedRepresentation))
    }
}
