import Foundation
import Testing
@testable import ContentPreview

struct HTMLCharacterReferencePreviewTests {
    // WHATWG parsing.html §13.2.5.78 and §13.2.5.80–84. These fixtures
    // exercise copied body/textarea text; attributes are never decoded.
    @Test(arguments: [
        ("&#65abc &#x41gives &#X1F600tail", "Aabc Agives 😀tail"),
        ("&#65=1 &#65 &#x41", "A=1 A A"),
        ("&#00065; &#128; &#x80!", "A € €!"),
        ("&#0; &#xD800; &#1114112; &#xFFFFFFFFFFFFFFFF;", "� � � �"),
        ("&#; &#x; &#XG1; &#-65; &unknown;", "&#; &#x; &#XG1; &#-65; &unknown;"),
        ("&copycat &ampersand; &reg=1 &nbspx", "©cat &ersand; ®=1 \u{A0}x"),
        ("&amp;copy; &#38;copy; &#x3C;b&#62;", "&copy; &copy; <b>"),
    ])
    func copiedHTMLUsesReferencePrefixesWithoutConsumingTheFollowingText(
        source: String, expected: String
    ) async throws {
        for element in ["p", "textarea"] {
            let text = try await historyPane("<\(element)>\(source)</\(element)>")
            #expect(Data(text.text.utf8) == Data(expected.utf8))
            #expect(!text.wasTruncated)
        }
    }

    @Test func numericReferencesConsumeAllDigitsWithoutAnIntegerOrSpellingLimit() async throws {
        let leadingZeros = String(repeating: "0", count: 8_192)
        let excessiveDigits = String(repeating: "9", count: 8_192)
        let text = try await historyPane(
            "<p>&#\(leadingZeros)65abc &#\(excessiveDigits);tail &#x\(leadingZeros)41g</p>"
        )
        #expect(text.text == "Aabc �tail Ag")
        #expect(!text.wasTruncated)
    }

    @Test func decodedMarkupStaysInertAndAttributesNeverContributeText() async throws {
        let text = try await historyPane("""
            <a href="file:///private/&#65;">&#60;img src="https://example.invalid"&#62;</a>
            <script>&#65abc</script><style>&copycat</style>
            <template>&#66abc</template><p>visible</p>
            """)
        #expect(text.text == "<img src=\"https://example.invalid\">\nvisible")
        #expect(!text.wasTruncated)
    }

    @Test func expandedReferencesStillRespectGraphemeAndByteBudgets() throws {
        let outcome = PreviewHTMLRenderer.render(
            Data("<p>abcd&#101;&#769;tail</p>".utf8),
            maximumInputBytes: 1_024, maximumOutputBytes: 5
        )
        let text = try artifact(outcome)
        #expect(text.text == "abcd")
        #expect(text.wasTruncated)
    }

    private func historyPane(_ source: String) async throws -> PreviewText {
        try artifact(await ContentPreview().renderHistoryPane([
            PreviewRepresentation(typeIdentifier: "public.html", bytes: Data(source.utf8)),
        ]))
    }

    private func artifact(_ outcome: PreviewOutcome) throws -> PreviewText {
        guard case .content(.text(let text)) = outcome else {
            Issue.record("Expected inert HTML text, got \(outcome)")
            throw UnexpectedOutcome()
        }
        return text
    }

    private struct UnexpectedOutcome: Error {}
}
