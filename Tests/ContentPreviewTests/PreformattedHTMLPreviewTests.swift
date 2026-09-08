import Foundation
import Testing
@testable import ContentPreview

struct PreformattedHTMLPreviewTests {
    @Test(arguments: [
        ("<pre>\r\nlet x = 1\r\n  print(x)\r</pre>", "let x = 1\n  print(x)\n"),
        ("<pre>\n\nx\n</pre>", "\nx\n"),
        ("<pre>\r\r\nx</pre>", "\nx"),
        ("<pre> \n x\t y</pre>", " \n x\t y"),
        ("<pre>&#10;x&#13;y</pre>", "x\ry"),
        ("<pre>&#13;\nx</pre>", "\r\nx"),
        ("<pre><!-- comment -->\nx</pre>", "\nx"),
        ("<pre><code>\nx</code></pre>", "\nx"),
        ("<pre>\r\nA</pre><pre>\nB</pre>", "A\nB"),
        ("<pre>\nA<script>\r\nsecret\r</script>B</pre>", "AB"),
        ("<template><pre>\r\nsecret</pre></template><pre>\nvisible</pre>", "visible"),
    ])
    func copiedCodePreservesVisibleWhitespace(source: String, expected: String) async throws {
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.html", bytes: Data(source.utf8)),
        ])
        let text = try artifact(outcome)
        #expect(Data(text.text.utf8) == Data(expected.utf8))
        #expect(!text.wasTruncated)
    }

    @Test func inputNewlineNormalizationWorksForBOMDeclaredUTF16() async throws {
        let source = "<pre>\r\n你好\r\n  世界</pre>"
        let encoded = try #require(source.data(using: .utf16BigEndian))
        let outcome = await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.html", bytes: Data([0xFE, 0xFF]) + encoded),
        ])
        let text = try artifact(outcome)
        #expect(Data(text.text.utf8) == Data("你好\n  世界".utf8))
        #expect(!text.wasTruncated)
    }

    @Test func normalizedNewlinesUseTheVisibleByteBudget() throws {
        let outcome = PreviewHTMLRenderer.render(
            Data("<pre>\r\nA\r\nB</pre>".utf8), maximumInputBytes: 100, maximumOutputBytes: 3
        )
        let text = try artifact(outcome)
        #expect(text.text == "A\nB")
        #expect(!text.wasTruncated)

        let truncated = try artifact(PreviewHTMLRenderer.render(
            Data("<pre>\r\nA\r\nBe\u{301}</pre>".utf8),
            maximumInputBytes: 100, maximumOutputBytes: 4
        ))
        #expect(truncated.text == "A\nB")
        #expect(truncated.wasTruncated)
    }

    private func artifact(_ outcome: PreviewOutcome) throws -> PreviewText {
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected preformatted HTML text, got \(outcome)")
            throw UnexpectedOutcome()
        }
        return text
    }

    private struct UnexpectedOutcome: Error {}
}
