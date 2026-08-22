/// HistoryDetailsFormatSafetyTests — literal proofs for the Details row's
/// format-safe text presentation boundary (review TYPE-2).
import Foundation
import HistoryCore
import PresentationUI
import Testing

struct HistoryDetailsFormatSafetyTests {

    @Test func exactUTF8PlainTextDisplaysDecodedText() {
        let representation = HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data("Hello, Clipy — 你好".utf8)
        )

        #expect(
            DetailsRepresentationPresentation.resolve(representation)
                == .plainText("Hello, Clipy — 你好")
        )
    }

    /// Bytes being valid UTF-8 is not an encoding contract for structured,
    /// abstract, or encoding-unspecified text identifiers (review TYPE-2).
    @Test func textWithoutAnExactUTF8ContractStaysMetadataOnly() {
        let fixtures: [(String, String)] = [
            ("public.rtf", #"{\rtf1\ansi Literal RTF}"#),
            ("public.html", "<p>Literal HTML</p>"),
            ("public.text", "abstract text"),
            ("public.plain-text", "unspecified encoding"),
            ("public.utf16-plain-text", "not UTF-16"),
            ("public.utf8-external-plain-text", "external text"),
        ]

        for (typeIdentifier, literal) in fixtures {
            let representation = HistoryRepresentation(
                typeIdentifier: typeIdentifier,
                bytes: Data(literal.utf8)
            )

            #expect(
                DetailsRepresentationPresentation.resolve(representation)
                    == .metadataOnly,
                "\(typeIdentifier) must not be presented as UTF-8 plain text"
            )
        }
    }

    @Test func structuredRepresentationDoesNotConsumeItsPlainTextSibling() {
        let html = HistoryRepresentation(
            typeIdentifier: "public.html",
            bytes: Data("<p>Semantic sibling</p>".utf8)
        )
        let plainText = HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data("Semantic sibling".utf8)
        )

        #expect(
            DetailsRepresentationPresentation.resolve(html) == .metadataOnly
        )
        #expect(
            DetailsRepresentationPresentation.resolve(plainText)
                == .plainText("Semantic sibling")
        )
    }

    @Test func malformedOrEmptyExactUTF8StaysMetadataOnly() {
        let malformed = HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data([0xC3, 0x28])
        )
        let empty = HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data()
        )

        #expect(
            DetailsRepresentationPresentation.resolve(malformed)
                == .metadataOnly
        )
        #expect(
            DetailsRepresentationPresentation.resolve(empty) == .metadataOnly
        )
    }

    @Test func exactUTF8PreviewIsBoundedToFiveHundredCharacters() {
        let representation = HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data(String(repeating: "x", count: 501).utf8)
        )

        #expect(
            DetailsRepresentationPresentation.resolve(representation)
                == .plainText(String(repeating: "x", count: 500))
        )
    }
}
