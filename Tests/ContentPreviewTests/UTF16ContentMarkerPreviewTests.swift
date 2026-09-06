import ContentPreview
import Foundation
import Testing

struct UTF16ContentMarkerPreviewTests {
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
