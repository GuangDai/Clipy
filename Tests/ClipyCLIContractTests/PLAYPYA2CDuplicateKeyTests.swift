/// PLAY-PY-A2C — duplicates are compared after escape decoding, by exact UTF-8.
import ClipyCLIContract
import Foundation
import Testing

struct PLAYPYA2CDuplicateKeyTests {
    @Test func escapedAndLiteralSpellingsOfOneKeyAreDuplicates() {
        let input = Data(
            #"{"protocolVersion":1,"requestID":"9bd92054-bd3f-4d20-8f8a-5d77aa63b726","operation":"browsePreview","oper\u0061tion":"browsePreview","arguments":{"limit":20}}"#.utf8
        )

        #expect(failure(ClipyCLIContract.decodeRequest(input))?.code == .invalidJSON)
    }

    @Test func duplicateNestedArgumentKeyIsRejectedBeforeTypedConstruction() {
        let input = requestBytes(arguments: "{\"limit\":20,\"l\\u0069mit\":20}")

        #expect(failure(ClipyCLIContract.decodeRequest(input))?.code == .invalidJSON)
    }

    @Test func canonicallyEquivalentButByteDistinctKeysAreNotDuplicates() {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let input = requestBytes(
            arguments: "{\"limit\":20,\"\(composed)\":null,\"\(decomposed)\":null}"
        )

        // Both fields are unknown typed fields. Reaching typed rejection proves
        // the parser did not conflate their distinct decoded UTF-8 sequences.
        #expect(failure(ClipyCLIContract.decodeRequest(input))?.code == .invalidRequest)
    }
}
