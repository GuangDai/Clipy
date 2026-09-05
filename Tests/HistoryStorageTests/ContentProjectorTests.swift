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

@Test func titleOnlyProjectionMatchesFullProjection() {
    let content = effectiveTextContent([
        ("public.utf8-plain-text", " \n First title \nbody"),
        ("public.utf16-external-plain-text", String(repeating: "later", count: 80_000)),
    ])

    #expect(
        ContentProjector.projectTitle(content)
            == ContentProjector.project(content).title
    )
}

@Test func projectionSkipsLaterDecodesOnceTitleAndBodyBudgetsComplete() {
    let bound = HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes
    let exactFill = String(repeating: "b", count: bound)
    // The budget filler's first line IS the whole text, so the durable
    // title is that line truncated to the stored-title bound.
    let truncatedTitle = String(
        repeating: "b",
        count: HistoryLimits.standard.maximumStoredTitleUTF8Bytes
    )

    // The first representation fills the body budget exactly and yields
    // the title; the second textual representation can contribute neither
    // (its decode is skipped entirely) and the projection is unchanged.
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

    // Boundary lock for the skip itself: a whitespace-only leading
    // representation contributes neither title nor body, so the budget
    // filler still owns the title and the trailing text still adds nothing.
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

@Test func projectionV2KeepsStructuredAndAbstractTextOpaque() {
    let content = effectiveTextContent([
        ("public.html", "<h1>markup</h1>"),
        ("public.plain-text", "encoding unspecified"),
        ("public.rtf", #"{\rtf1 markup}"#),
        ("public.text", "abstract text"),
        ("public.utf8-plain-text", "Visible sibling"),
    ])

    let projection = ContentProjector.project(content)

    #expect(projection.schemaVersion == 3)
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

@Test(arguments: [String.Encoding.utf16, .utf16LittleEndian])
func explicitUTF16TypeDecodesUTF16WithoutUTF8Fallback(encoding: String.Encoding) {
    let text = "UTF-16 title"
    let content = EffectiveContent(representations: [ContentRepresentation(
        typeIdentifier: "public.utf16-plain-text",
        bytes: text.data(using: encoding)!
    )])

    let projection = ContentProjector.project(content)

    #expect(projection.title == text)
    #expect(projection.searchBody == text)
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
