import ContentPreview
import Foundation
import Testing

struct PreviewTextResourceTests {
    @Test func manyShortLinesAreAlsoSmallLayoutOperations() async {
        let source = String(repeating: "一二三\r\n", count: 200)
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8))
        ], textConfiguration: PreviewTextConfiguration(maximumCharacters: nil, segmentLineBreakBudget: 8))
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected the complete multiline text")
            return
        }
        #expect(text.displaySegments.count == 25)
        #expect(text.displaySegments.allSatisfy { $0 == String(repeating: "一二三\r\n", count: 8) })
        #expect(Data(text.displaySegments.joined().utf8) == Data(source.utf8))
        #expect(!text.wasTruncated)
    }
    @Test(arguments: [nil, 10_000, 80_000] as [Int?])
    func configuredLengthCanRetainCompleteTextOrAnyChosenPrefix(limit: Int?) async {
        let source = String(repeating: "x", count: 60_000) + "COMPLETE-TAIL"
        let representations = [
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8)),
            PreviewRepresentation(typeIdentifier: "public.html", bytes: Data(("<pre>" + source + "</pre>").utf8)),
            PreviewRepresentation(typeIdentifier: "public.rtf", bytes: Data(("{\\rtf1 " + source + "}").utf8))
        ]
        for representation in representations {
            let outcome = await ContentPreview().renderHistoryPane([representation],
                textConfiguration: PreviewTextConfiguration(maximumCharacters: limit))
            guard case .content(.text(let text)) = outcome else {
                Issue.record("Expected a configured text preview")
                continue
            }
            let expected = limit == 10_000 ? String(repeating: "x", count: 10_000) : source
            #expect(Data(text.text.utf8) == Data(expected.utf8))
            #expect(Data(text.displaySegments.joined().utf8) == Data(expected.utf8))
            #expect(text.wasTruncated == (limit == 10_000))
        }
    }

    @Test func layoutWorkBudgetNeverBecomesADocumentLengthLimit() async {
        let source = String(repeating: "e\u{301}🦊", count: 800)
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(source.utf8))
        ], textConfiguration: PreviewTextConfiguration(maximumCharacters: nil, segmentUTF16Budget: 64))
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected complete segmented Unicode text")
            return
        }
        #expect(Data(text.displaySegments.joined().utf8) == Data(source.utf8))
        #expect(text.displaySegments.allSatisfy { $0.utf16.count <= 64 })
        #expect(!text.wasTruncated)
    }

    @Test(arguments: ["public.utf8-plain-text", "public.html", "public.rtf"])
    func oversizedCombiningSequenceIsSegmentedWithoutDiscardingContent(type: String) async {
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
        #expect(!text.wasTruncated)
        #expect(Data(text.text.utf8) == Data((prefix + "e" + marks).utf8))
        #expect(Data(text.displaySegments.joined().utf8) == Data(text.text.utf8))
        #expect(text.displaySegments.count > 1)
        #expect(text.displaySegments.allSatisfy { $0.utf16.count <= 512 })
    }
}
