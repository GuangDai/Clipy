/// Bounded projection tests (docs/05-authority-kernel.md §15;
/// docs/06-cross-cutting.md §2, §9). Projection must discard whitespace-only
/// representations and construct the stored corpus without first materializing
/// an unbounded joined body.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

private func effectiveTextContent(
    _ representations: [(typeIdentifier: String, text: String)]
) -> EffectiveContent {
    EffectiveContent(
        representations: representations.map {
            ContentRepresentation(
                typeIdentifier: $0.typeIdentifier,
                bytes: $0.typeIdentifier == "public.utf16-external-plain-text"
                    ? $0.text.data(using: .utf16BigEndian)!
                    : Data($0.text.utf8)
            )
        }
    )
}

@Test func projectionSkipsWhitespaceOnlyRepresentations() {
    let content = effectiveTextContent([
        ("public.utf16-external-plain-text", " \r\n\t "),
        ("public.utf8-plain-text", "  Useful title\r\nbody "),
    ])

    let projection = ContentProjector.project(content)

    #expect(projection.title == "Useful title")
    #expect(projection.searchBody == "  Useful title\nbody ")
}

@Test func projectionStreamsSearchBodyAtUnicodeBoundary() {
    let bound = HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes
    let prefix = String(repeating: "a", count: bound - 1)
    let content = effectiveTextContent([
        ("public.utf8-plain-text", prefix),
        ("public.utf16-external-plain-text", "🙂tail"),
    ])

    let projection = ContentProjector.project(content)

    // The separator consumes the final byte. The following grapheme is not
    // split, and no later text is accumulated beyond the durable bound.
    #expect(projection.searchBody == prefix + "\n")
    #expect(projection.searchBody.utf8.count == bound)
}

@Test func titleOnlyProjectionMatchesNewlineAndWhitespaceSemantics() {
    let fixtures: [(String, String)] = [
        (" \r\n\t\r\n First title \rignored", "First title"),
        ("\r\n\r\n\n\r First title \nignored", "First title"),
        ("\u{00A0}\r e\u{301} 👩‍💻 \r\nignored", "e\u{301} 👩‍💻"),
        ("First\u{2028}Second\u{0085}Third\rignored", "First\u{2028}Second\u{0085}Third"),
        (" \r\n\t\r\u{00A0}\n", "public.utf8-plain-text"),
    ]
    for (text, expected) in fixtures {
        let content = effectiveTextContent([
            ("public.utf8-plain-text", text),
        ])
        let title = ContentProjector.projectTitle(content)
        // String equality alone would hide a change to Unicode normalization.
        #expect(Data(title.utf8) == Data(expected.utf8))
        #expect(Data(title.utf8) == Data(ContentProjector.project(content).title.utf8))
    }
}

@Test func titleOnlyProjectionKeepsGraphemesAtTheByteLimitBeforeALargeBody() {
    let prefix = String(
        repeating: "a",
        count: HistoryLimits.standard.maximumStoredTitleUTF8Bytes - 1
    )
    let text = "\r\n " + prefix + "e\u{301} \r\n"
        + String(repeating: "large body\r\n", count: 50_000)
    for identifier in ["public.utf8-plain-text", "public.utf16-external-plain-text"] {
        let content = effectiveTextContent([(identifier, text)])
        let title = ContentProjector.projectTitle(content)
        // The decomposed grapheme needs three bytes and cannot fit in the
        // final one-byte slot. Neither its base nor its accent may be split.
        #expect(Data(title.utf8) == Data(prefix.utf8))
        #expect(Data(title.utf8) == Data(ContentProjector.project(content).title.utf8))
    }
}

@Test func titleOnlyProjectionStillRejectsMalformedBytesAfterAValidFirstLine() {
    let content = EffectiveContent(representations: [ContentRepresentation(
        typeIdentifier: "public.utf8-plain-text",
        bytes: Data("Valid first line\r\n".utf8) + Data([0xC3, 0x28])
    )])
    #expect(ContentProjector.projectTitle(content) == "public.utf8-plain-text")
}

@Test func completedTitleAndBodyBudgetsExcludeLaterText() {
    let bound = HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes
    let exactFill = String(repeating: "b", count: bound)
    // The budget filler's first line IS the whole text, so the durable
    // title is that line truncated to the stored-title bound.
    let truncatedTitle = String(
        repeating: "b",
        count: HistoryLimits.standard.maximumStoredTitleUTF8Bytes
    )

    // The first representation fills the body budget exactly and yields
    // the title; later text contributes neither. These output assertions
    // establish the budgets, not how many decoder calls were made.
    let content = effectiveTextContent([
        ("public.utf8-plain-text", exactFill),
        ("public.utf16-external-plain-text", "decoded but contributes nothing"),
    ])
    let projection = ContentProjector.project(content)
    #expect(projection.searchBody == exactFill)
    #expect(projection.title == truncatedTitle)
    #expect(
        projection.effectiveTypeIdentifiers
            == ["public.utf8-plain-text", "public.utf16-external-plain-text"]
    )

    // An encoding-unspecified leading representation remains opaque, so
    // the budget filler still owns the title and body.
    let trailing = effectiveTextContent([
        ("public.plain-text", " \n "),
        ("public.utf8-plain-text", exactFill),
        ("public.utf16-external-plain-text", "late tail text"),
    ])
    let trailingProjection = ContentProjector.project(trailing)
    #expect(trailingProjection.searchBody == exactFill)
    #expect(trailingProjection.title == truncatedTitle)
}

@Test func projectionNormalizesCRLFAndLoneCRInOnePass() {
    let content = effectiveTextContent([
        ("public.utf8-plain-text", "\r\n  First\rSecond\r\nThird"),
    ])

    let projection = ContentProjector.project(content)

    #expect(projection.title == "First")
    #expect(projection.searchBody == "\n  First\nSecond\nThird")
}

@Test func malformedUTF8DoesNotFallBackToMojibakeUTF16() {
    let content = EffectiveContent(representations: [ContentRepresentation(
        typeIdentifier: "public.utf8-plain-text",
        bytes: Data([0xFF, 0xFE, 0x00, 0xD8])
    )])

    let projection = ContentProjector.project(content)

    #expect(projection.title == "public.utf8-plain-text")
    #expect(projection.searchBody.isEmpty)
}

@Test func projectionKeepsStructuredAndAbstractTextOpaque() {
    let content = effectiveTextContent([
        ("public.html", "<h1>markup</h1>"),
        ("public.plain-text", "encoding unspecified"),
        ("public.rtf", #"{\rtf1 markup}"#),
        ("public.text", "abstract text"),
        ("public.utf8-plain-text", "Visible sibling"),
    ])

    let projection = ContentProjector.project(content)

    #expect(projection.schemaVersion == 4)
    #expect(projection.title == "Visible sibling")
    #expect(projection.searchBody == "Visible sibling")
    #expect(
        projection.effectiveTypeIdentifiers == [
            "public.html",
            "public.plain-text",
            "public.rtf",
            "public.text",
            "public.utf8-plain-text",
        ]
    )
}

@Test(arguments: [
    Data([0x41, 0x00, 0x2D, 0x4E, 0x3E, 0xD8, 0x8A, 0xDD]),
    Data([0xFF, 0xFE, 0x41, 0x00, 0x2D, 0x4E, 0x3E, 0xD8, 0x8A, 0xDD]),
    Data([0xFE, 0xFF, 0x00, 0x41, 0x4E, 0x2D, 0xD8, 0x3E, 0xDD, 0x8A]),
])
func nativeUTF16ProjectionHonorsByteOrder(bytes: Data) {
    // Literal bytes distinguish native no-BOM order from both BOM overrides
    // without using Foundation's encoder as the decoder's test oracle.
    let content = EffectiveContent(representations: [ContentRepresentation(
        typeIdentifier: "public.utf16-plain-text",
        bytes: bytes
    )])

    let projection = ContentProjector.project(content)

    #expect(projection.title == "A中🦊")
    #expect(projection.searchBody == "A中🦊")
    #expect(ContentProjector.projectTitle(content) == "A中🦊")
}

@Test(arguments: [
    Data([0x00, 0x41, 0x4E, 0x2D]),
    Data([0xFE, 0xFF, 0x00, 0x41, 0x4E, 0x2D]),
    Data([0xFF, 0xFE, 0x41, 0x00, 0x2D, 0x4E]),
])
func externalUTF16ProjectionHonorsByteOrder(bytes: Data) {
    let content = EffectiveContent(representations: [ContentRepresentation(
        typeIdentifier: "public.utf16-external-plain-text",
        bytes: bytes
    )])
    let projection = ContentProjector.project(content)
    #expect(projection.title == "A中")
    #expect(projection.searchBody == "A中")
    #expect(ContentProjector.projectTitle(content) == "A中")
}

@Test func misspelledExternalUTF8IdentifierRemainsOpaque() {
    let content = effectiveTextContent([
        ("public.utf8-external-plain-text", "Must not become searchable"),
    ])
    let projection = ContentProjector.project(content)
    #expect(projection.title == "public.utf8-external-plain-text")
    #expect(projection.searchBody.isEmpty)
}

@Test func storedProjectionValidationReturnsItsExistingUTF8Counts() throws {
    let title = "Title 🙂"
    let body = "Body with e\u{301} and 🇺🇳"

    let size = try ContentProjector.validateStoredProjection(
        schemaVersion: ContentProjector.schemaVersion,
        title: title,
        searchBody: body,
        limits: .standard
    )

    #expect(size.titleUTF8Bytes == title.utf8.count)
    #expect(size.searchBodyUTF8Bytes == body.utf8.count)
}

@Test func ordinaryReadsRequireRecipeFourAfterStartupRebuild() throws {
    #expect(throws: CodecRejection.unknownProjectionSchemaVersion(found: 3)) {
        try ContentProjector.validateStoredProjection(
            schemaVersion: 3, title: "A", searchBody: "A", limits: .standard
        )
    }
    let current = try ContentProjector.validateStoredProjection(
        schemaVersion: 4, title: "A", searchBody: "A", limits: .standard
    )
    #expect(current.titleUTF8Bytes == 1)
    #expect(current.searchBodyUTF8Bytes == 1)
}
