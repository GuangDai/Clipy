/// Literal byte contracts for editor replacement. Each format keeps its
/// original byte order and BOM style, including when the replacement text
/// contains surrogate pairs or decomposed combining characters.
import Foundation
import HistoryCore
import PresentationUI
import Testing

struct EditorTextCodecTests {
    struct Fixture: Sendable {
        let type: String
        let original: [UInt8]
        let replacement: [UInt8]
    }

    struct MalformedFixture: Sendable {
        let type: String
        let seed: [UInt8]
        let malformed: [UInt8]
    }

    @Test(arguments: [
        Fixture(
            type: "public.utf8-plain-text",
            original: [0x41, 0xCE, 0xA9, 0xF0, 0x9F, 0xA6, 0x8A, 0x65, 0xCC, 0x81],
            replacement: [0x42, 0xF0, 0x9F, 0xA6, 0x8A, 0x6F, 0xCC, 0x88]
        ),
        Fixture(
            type: "public.utf16-plain-text",
            original: [0x41, 0x00, 0xA9, 0x03, 0x3E, 0xD8, 0x8A, 0xDD, 0x65, 0x00, 0x01, 0x03],
            replacement: [0x42, 0x00, 0x3E, 0xD8, 0x8A, 0xDD, 0x6F, 0x00, 0x08, 0x03]
        ),
        Fixture(
            type: "public.utf16-plain-text",
            original: [0xFF, 0xFE, 0x41, 0x00, 0xA9, 0x03, 0x3E, 0xD8, 0x8A, 0xDD, 0x65, 0x00, 0x01, 0x03],
            replacement: [0xFF, 0xFE, 0x42, 0x00, 0x3E, 0xD8, 0x8A, 0xDD, 0x6F, 0x00, 0x08, 0x03]
        ),
        Fixture(
            type: "public.utf16-plain-text",
            original: [0xFE, 0xFF, 0x00, 0x41, 0x03, 0xA9, 0xD8, 0x3E, 0xDD, 0x8A, 0x00, 0x65, 0x03, 0x01],
            replacement: [0xFE, 0xFF, 0x00, 0x42, 0xD8, 0x3E, 0xDD, 0x8A, 0x00, 0x6F, 0x03, 0x08]
        ),
        Fixture(
            type: "public.utf16-external-plain-text",
            original: [0x00, 0x41, 0x03, 0xA9, 0xD8, 0x3E, 0xDD, 0x8A, 0x00, 0x65, 0x03, 0x01],
            replacement: [0x00, 0x42, 0xD8, 0x3E, 0xDD, 0x8A, 0x00, 0x6F, 0x03, 0x08]
        ),
        Fixture(
            type: "public.utf16-external-plain-text",
            original: [0xFF, 0xFE, 0x41, 0x00, 0xA9, 0x03, 0x3E, 0xD8, 0x8A, 0xDD, 0x65, 0x00, 0x01, 0x03],
            replacement: [0xFF, 0xFE, 0x42, 0x00, 0x3E, 0xD8, 0x8A, 0xDD, 0x6F, 0x00, 0x08, 0x03]
        ),
        Fixture(
            type: "public.utf16-external-plain-text",
            original: [0xFE, 0xFF, 0x00, 0x41, 0x03, 0xA9, 0xD8, 0x3E, 0xDD, 0x8A, 0x00, 0x65, 0x03, 0x01],
            replacement: [0xFE, 0xFF, 0x00, 0x42, 0xD8, 0x3E, 0xDD, 0x8A, 0x00, 0x6F, 0x03, 0x08]
        ),
    ])
    func replacementPreservesEncodingAndExactUnicodeScalars(_ fixture: Fixture) throws {
        let original = Data(fixture.original)
        let decodedSource = try #require(EditorTextCodec.decode(HistoryRepresentation(
            typeIdentifier: fixture.type, bytes: original
        )))
        let codec = decodedSource.codec
        let decoded = decodedSource.text
        // String equality treats canonical-equivalent forms as equal. Scalar
        // equality also proves the combining sequence was not normalized.
        #expect(decoded.unicodeScalars.map(\.value) == [0x41, 0x3A9, 0x1F98A, 0x65, 0x301])
        #expect(codec.encode(decoded) == original)
        #expect(codec.encode("B🦊o\u{308}") == Data(fixture.replacement))
    }

    @Test(arguments: [
        MalformedFixture(type: "public.utf8-plain-text", seed: [0x41], malformed: [0xC3, 0x28]),
        MalformedFixture(type: "public.utf8-plain-text", seed: [0x41], malformed: [0xED, 0xA0, 0x80]),
        MalformedFixture(type: "public.utf16-plain-text", seed: [0x41, 0x00], malformed: [0x41]),
        MalformedFixture(type: "public.utf16-plain-text", seed: [0x41, 0x00], malformed: [0x00, 0xD8]),
        MalformedFixture(type: "public.utf16-plain-text", seed: [0x41, 0x00], malformed: [0x00, 0xDC]),
        MalformedFixture(type: "public.utf16-plain-text", seed: [0x41, 0x00], malformed: [0x00, 0xD8, 0x41, 0x00]),
        MalformedFixture(type: "public.utf16-external-plain-text", seed: [0x00, 0x41], malformed: [0x41]),
        MalformedFixture(type: "public.utf16-external-plain-text", seed: [0x00, 0x41], malformed: [0xD8, 0x00]),
        MalformedFixture(type: "public.utf16-external-plain-text", seed: [0x00, 0x41], malformed: [0xDC, 0x00]),
        MalformedFixture(type: "public.utf16-external-plain-text", seed: [0x00, 0x41], malformed: [0xD8, 0x00, 0x00, 0x41]),
        MalformedFixture(type: "public.utf16-plain-text", seed: [0xFE, 0xFF, 0x00, 0x41], malformed: [0xFE, 0xFF, 0xD8, 0x00]),
        MalformedFixture(type: "public.utf16-external-plain-text", seed: [0xFF, 0xFE, 0x41, 0x00], malformed: [0xFF, 0xFE, 0x00, 0xDC]),
        MalformedFixture(type: "public.utf16-external-plain-text", seed: [0xFF, 0xFE, 0x41, 0x00], malformed: [0xFF, 0xFE, 0x41]),
    ])
    func malformedUnicodeIsRejectedWithoutReplacementCharacters(_ fixture: MalformedFixture) throws {
        let bytes = Data(fixture.malformed)
        #expect(EditorTextCodec.matching(HistoryRepresentation(
            typeIdentifier: fixture.type, bytes: bytes
        )) == nil)
        #expect(EditorTextCodec.decode(HistoryRepresentation(
            typeIdentifier: fixture.type, bytes: bytes
        )) == nil)
        let codec = try #require(EditorTextCodec.matching(HistoryRepresentation(
            typeIdentifier: fixture.type, bytes: Data(fixture.seed)
        )))
        #expect(codec.decode(bytes) == nil)
    }

    @Test func utf8LeadingFEFFRemainsText() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF, 0x41])
        let codec = try #require(EditorTextCodec.matching(HistoryRepresentation(
            typeIdentifier: "public.utf8-plain-text", bytes: bytes
        )))
        let decoded = try #require(codec.decode(bytes))
        #expect(decoded.unicodeScalars.map(\.value) == [0xFEFF, 0x41])
        #expect(codec.encode(decoded) == bytes)
    }

    @Test(arguments: [
        Fixture(type: "public.utf16-plain-text",
                original: [0xFF, 0xFE, 0xFF, 0xFE, 0x41, 0x00], replacement: [0xFF, 0xFE, 0x42, 0x00]),
        Fixture(type: "public.utf16-external-plain-text",
                original: [0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x41], replacement: [0xFE, 0xFF, 0x00, 0x42]),
    ])
    func secondUTF16MarkIsPreservedAsText(_ fixture: Fixture) throws {
        let bytes = Data(fixture.original)
        let codec = try #require(EditorTextCodec.matching(HistoryRepresentation(
            typeIdentifier: fixture.type, bytes: bytes
        )))
        let decoded = try #require(codec.decode(bytes))
        #expect(decoded.unicodeScalars.map(\.value) == [0xFEFF, 0x41])
        #expect(codec.encode(decoded) == bytes)
        #expect(codec.encode("B") == Data(fixture.replacement))
    }

    @Test(arguments: [
        Fixture(type: "public.utf8-plain-text", original: [], replacement: []),
        Fixture(type: "public.utf16-plain-text", original: [], replacement: []),
        Fixture(type: "public.utf16-plain-text", original: [0xFF, 0xFE], replacement: [0xFF, 0xFE]),
        Fixture(type: "public.utf16-external-plain-text", original: [], replacement: []),
        Fixture(type: "public.utf16-external-plain-text", original: [0xFE, 0xFF], replacement: [0xFE, 0xFF]),
    ])
    func emptyUnicodeRetainsCodecStyleWhileDraftOwnsEmptySubmission(_ fixture: Fixture) throws {
        let bytes = Data(fixture.original)
        let codec = try #require(EditorTextCodec.matching(HistoryRepresentation(
            typeIdentifier: fixture.type, bytes: bytes
        )))
        #expect(codec.decode(bytes) == "")
        #expect(codec.encode("") == Data(fixture.replacement))
    }

    @Test func bomLessUTF16DisambiguatesNewLeadingBOMScalarsOnReopen() throws {
        let fixtures: [(type: String, seed: [UInt8], text: String, expected: [UInt8])] = [
            ("public.utf16-plain-text", [0x41, 0x00], "\u{FEFF}A",
             [0xFF, 0xFE, 0xFF, 0xFE, 0x41, 0x00]),
            ("public.utf16-plain-text", [0x41, 0x00], "\u{FFFE}A",
             [0xFF, 0xFE, 0xFE, 0xFF, 0x41, 0x00]),
            ("public.utf16-external-plain-text", [0x00, 0x41], "\u{FEFF}A",
             [0xFE, 0xFF, 0xFE, 0xFF, 0x00, 0x41]),
            ("public.utf16-external-plain-text", [0x00, 0x41], "\u{FFFE}A",
             [0xFE, 0xFF, 0xFF, 0xFE, 0x00, 0x41]),
        ]
        for fixture in fixtures {
            let codec = try #require(EditorTextCodec.matching(HistoryRepresentation(
                typeIdentifier: fixture.type, bytes: Data(fixture.seed)
            )))
            let encoded = codec.encode(fixture.text)
            #expect(encoded == Data(fixture.expected))
            #expect(codec.decode(encoded)?.unicodeScalars.map(\.value)
                == fixture.text.unicodeScalars.map(\.value))
            let reopened = try #require(EditorTextCodec.matching(HistoryRepresentation(
                typeIdentifier: fixture.type, bytes: encoded
            )))
            let decoded = try #require(reopened.decode(encoded))
            #expect(decoded.unicodeScalars.map(\.value) == fixture.text.unicodeScalars.map(\.value))
            #expect(reopened.encode(decoded) == encoded)
            #expect(codec.encode("A") == Data(fixture.seed))
        }
    }

    @Test(arguments: [
        "public.plain-text", "public.text", "public.rtf", "public.html",
        "public.utf8-external-plain-text", "public.utf8-plain-text.private",
        "public.utf16-plain-text.private", "public.utf16-external-plain-text.private",
        "PUBLIC.UTF16-PLAIN-TEXT", "dyn.example", "com.example.unknown",
    ])
    func undeclaredOrSimilarIdentifiersDoNotAdmitReplacement(_ type: String) {
        #expect(EditorTextCodec.matching(HistoryRepresentation(
            typeIdentifier: type, bytes: Data([0x41, 0x00])
        )) == nil)
    }
}
