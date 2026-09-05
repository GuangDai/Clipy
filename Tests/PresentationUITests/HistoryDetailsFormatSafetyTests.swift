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
    @Test func textWithoutAnExactEncodingContractStaysMetadataOnly() {
        let fixtures: [(String, String)] = [
            ("public.rtf", #"{\rtf1\ansi Literal RTF}"#),
            ("public.html", "<p>Literal HTML</p>"),
            ("public.text", "abstract text"),
            ("public.plain-text", "unspecified encoding"),
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

    @Test func nativeAndExternalUTF16RespectByteOrderAndBOM() {
        let fixtures: [(String, Data)] = [
            ("public.utf16-plain-text", Data([0x41, 0x00, 0xA9, 0x03])),
            ("public.utf16-external-plain-text", Data([0x00, 0x41, 0x03, 0xA9])),
            ("public.utf16-plain-text", Data([0xFE, 0xFF, 0x00, 0x41, 0x03, 0xA9])),
            ("public.utf16-external-plain-text", Data([0xFF, 0xFE, 0x41, 0x00, 0xA9, 0x03])),
        ]
        for (typeIdentifier, bytes) in fixtures {
            #expect(
                DetailsRepresentationPresentation.resolve(
                    HistoryRepresentation(typeIdentifier: typeIdentifier, bytes: bytes)
                ) == .plainText("AΩ")
            )
        }
    }

    @Test func malformedOrEmptyUTF16StaysMetadataOnly() {
        for identifier in ["public.utf16-plain-text", "public.utf16-external-plain-text"] {
            for bytes in [Data(), Data([0x41]), Data([0xFF, 0xFE]), Data([0xFE, 0xFF, 0x41])] {
                #expect(
                    DetailsRepresentationPresentation.resolve(
                        HistoryRepresentation(typeIdentifier: identifier, bytes: bytes)
                    ) == .metadataOnly
                )
            }
        }
    }

    @Test func utf16PreviewPreservesWholeCharactersAtDisplayLimit() throws {
        let body = String(repeating: "🦊", count: 501)
        let bytes = try #require(body.data(using: .utf16BigEndian))
        #expect(
            DetailsRepresentationPresentation.resolve(
                HistoryRepresentation(
                    typeIdentifier: "public.utf16-external-plain-text",
                    bytes: bytes
                )
            ) == .plainText(String(repeating: "🦊", count: 500))
        )
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
