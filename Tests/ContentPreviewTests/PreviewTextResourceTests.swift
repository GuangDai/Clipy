import ContentPreview
import Foundation
import Testing

struct PreviewTextResourceTests {
    @Test(arguments: ["public.utf8-plain-text", "public.html", "public.rtf"])
    func oversizedCombiningSequenceNeverReachesTextLayout(type: String) async {
        let prefix = "Readable prefix\n"
        let marks = String(repeating: "\u{301}", count: 20_000)
        let bytes: Data
        switch type {
        case "public.html": bytes = Data(("<pre>" + prefix + "e" + marks + "</pre>").utf8)
        case "public.rtf":
            bytes = Data(("{\\rtf1 Readable prefix\\par e" + String(repeating: "\\u769?", count: 20_000) + "}").utf8)
        default: bytes = Data((prefix + "e" + marks).utf8)
        }
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: type, bytes: bytes)
        ])
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected the readable source prefix")
            return
        }
        #expect(text.wasTruncated)
        #expect(text.text == prefix)
    }
}
