/// StableFormatFactsTests — literal proofs for the Foundation-only format
/// facts shared by behavior owners. Purpose-specific admission is deliberately
/// outside this seam (review 08 §4.1; 06 §9).
import ClipboardFormats
import Testing

struct StableFormatFactsTests {
    @Test func exactPlainTextIdentifiersDeclareOnlyTheirOwnedCodecs() {
        #expect(
            ClipboardFormatIdentifier.utf8PlainText.rawValue
                == "public.utf8-plain-text"
        )
        #expect(
            ClipboardFormatIdentifier.utf8ExternalPlainText.rawValue
                == "public.utf8-external-plain-text"
        )
        #expect(
            ClipboardFormatIdentifier.utf16PlainText.rawValue
                == "public.utf16-plain-text"
        )
        #expect(
            ClipboardFormatIdentifier.utf8PlainText.declaredStringCodec
                == .utf8
        )
        #expect(
            ClipboardFormatIdentifier.utf8ExternalPlainText.declaredStringCodec
                == .utf8
        )
        #expect(
            ClipboardFormatIdentifier.utf16PlainText.declaredStringCodec
                == .nativeUTF16
        )
    }

    @Test func structuredAbstractAndUnspecifiedTextDeclareNoStringCodec() {
        let opaqueIdentifiers: [ClipboardFormatIdentifier] = [
            .plainText,
            .text,
            .rtf,
            .html,
        ]

        #expect(opaqueIdentifiers.allSatisfy {
            $0.declaredStringCodec == nil
        })
    }

    @Test func unknownIdentifierRemainsAnOpaqueRawValue() {
        let unknown = ClipboardFormatIdentifier(
            rawValue: "com.example.private-clipboard-value"
        )

        #expect(unknown.rawValue == "com.example.private-clipboard-value")
        #expect(unknown.declaredStringCodec == nil)
    }
}
