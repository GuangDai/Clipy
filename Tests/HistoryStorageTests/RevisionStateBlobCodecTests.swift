/// RevisionStateBlobCodec tests (roadmap step 4, codec B): §7.3 round trips —
/// full revision lineage, active Revision ID, occurrence first/last source,
/// pin ordinal, and Content Version survival — plus one rejection test per
/// docs/05-authority-kernel.md §4 decode check (docs/06-cross-cutting.md
/// §7.4), each failing closed as `.persistence(.corruptStoredValue)`.
///
/// Invalid-but-decodable blobs are crafted through the production serializer
/// `encodeWire` so every rejection test exercises the exact production
/// container format. Package-only Domain members are reachable from this
/// same-package test target via `@testable import`.
import Foundation
import Testing
import HistoryCore
import HistoryDomain
@testable import HistoryStorage

struct RevisionStateBlobCodecTests {

// MARK: - Fixtures

internal static let pngType = "public.png"
internal static let textType = "public.utf8-plain-text"
internal static let tiffType = "public.tiff"

internal static let revisionUUID1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
internal static let revisionUUID2 = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
internal static let foreignUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

/// The item's Canonical Content: two normalized representations (PNG sorts
/// before UTF-8 text in stable Unicode scalar order).
internal func makeCanonical() throws -> CanonicalContent {
    try CanonicalContent(representations: [
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: Self.pngType,
                bytes: Data([0x89, 0x50])
            ),
            fingerprint: ContentFingerprint(rawValue: 11)
        ),
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: Self.textType,
                bytes: Data([0x68, 0x69])
            ),
            fingerprint: ContentFingerprint(rawValue: 22)
        ),
    ])
}

internal func makeRevision(
    id: UUID,
    createdAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
    representations: [(String, [UInt8])] = [(Self.textType, [0x68, 0x65, 0x6C, 0x6C, 0x6F])]
) -> ContentRevision {
    ContentRevision(
        id: RevisionID(rawValue: id),
        createdAt: createdAt,
        content: EffectiveContent(
            representations: representations.map { pair in
                ContentRepresentation(typeIdentifier: pair.0, bytes: Data(pair.1))
            }
        )
    )
}

internal func storedRepresentation(
    _ typeIdentifier: String,
    _ bytes: [UInt8]
) -> StoredRepresentationV1 {
    StoredRepresentationV1(typeIdentifier: typeIdentifier, bytes: Data(bytes))
}

internal func storedRevision(
    _ id: UUID,
    createdAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
    representations: [StoredRepresentationV1]
) -> StoredRevisionV1 {
    StoredRevisionV1(
        id: id,
        createdAt: createdAt,
        representations: representations
    )
}

/// Serializes a wire value through the production container format so a
/// rejection test crafts its corrupt blob exactly the way production writes
/// valid ones (docs/06-cross-cutting.md §7.4).
internal func wireBlob(
    formatVersion: UInt16 = 1,
    revisions: [StoredRevisionV1],
    activeRevisionID: UUID?
) throws -> Data {
    try RevisionStateBlobCodec.encodeWire(
        RevisionStateBlobV1(
            formatVersion: formatVersion,
            revisions: revisions,
            activeRevisionID: activeRevisionID
        )
    )
}

/// Bounds far below `HistoryLimits.standard` so the §4 bound checks run
/// without large fixtures. The defaults keep every fixture blob well under
/// the decode envelope.
internal func smallLimits(
    maximumRepresentationsPerCaptureOrRevision: Int = 4,
    maximumTypeIdentifierUTF8Bytes: Int = 64,
    maximumRepresentationBytes: Int = 64,
    maximumProposedRevisionBytes: Int = 64,
    maximumRevisionsPerItem: Int = 2,
    maximumTotalRevisionBytesPerItem: Int = 128,
    maximumSourceApplicationObservationUTF8Bytes: Int = 16
) -> HistoryLimits {
    HistoryLimits(
        maximumRepresentationsPerCaptureOrRevision: maximumRepresentationsPerCaptureOrRevision,
        maximumTypeIdentifierUTF8Bytes: maximumTypeIdentifierUTF8Bytes,
        maximumRepresentationBytes: maximumRepresentationBytes,
        maximumCaptureBytes: 2 * maximumRepresentationBytes,
        maximumProposedRevisionBytes: maximumProposedRevisionBytes,
        maximumRevisionsPerItem: maximumRevisionsPerItem,
        maximumTotalRevisionBytesPerItem: maximumTotalRevisionBytesPerItem,
        hardMaximumRetainedItems: 100,
        userMaximumUnpinnedLowerBound: 1,
        userMaximumUnpinnedUpperBound: 100,
        defaultMaximumUnpinnedItems: 50,
        maximumSourceApplicationObservationUTF8Bytes: maximumSourceApplicationObservationUTF8Bytes,
        maximumStoredTitleUTF8Bytes: 64,
        maximumStoredSearchBodyUTF8Bytes: 128,
        pageRowLimitLowerBound: 1,
        pageRowLimitUpperBound: 100,
        maximumSearchTermUTF8Bytes: 64,
        maximumRegexpPatternCharacters: 64,
        maximumFuzzyQueryCharacters: 64,
        maximumFuzzyTitleBodyPrefixCharacters: 64,
        maximumRegexpTitleBodyPrefixCharacters: 64,
        maximumBodySearchSnippetCharacters: 64,
        thumbnailDimensionLowerBound: 1,
        thumbnailDimensionUpperBound: 64,
        maximumEncodedThumbnailBytes: 1_024
    )!
}

// MARK: - Round trips (docs/06-cross-cutting.md §7.3)

/// A Canonical-state item: empty revision list, nil active ID, no revision
/// bytes (docs/05-authority-kernel.md §3.1, D3).
@Test func roundTripPreservesCanonicalStateItem() throws {
    let canonical = try makeCanonical()
    let blob = try RevisionStateBlobCodec.encode(revisions: [], activeRevisionID: nil)

    let decoded = try RevisionStateBlobCodec.decode(blob, canonical: canonical)

    #expect(decoded.revisions.isEmpty)
    #expect(decoded.activeRevisionID == nil)
}

/// Full revision lineage survival: every revision (ID, creation time, and
/// complete content snapshot) and the active Revision ID survive the round
/// trip (§7.3: "full revisions including the active revision, active ID").
@Test func roundTripPreservesFullRevisionLineage() throws {
    let canonical = try makeCanonical()
    // Dyadic fractional seconds are exactly representable, so the timestamp
    // comparison is an exact-fidelity check of the container format.
    let revisions = [
        makeRevision(
            id: Self.revisionUUID1,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_234_567.25),
            representations: [(Self.textType, [0x76, 0x31])]
        ),
        makeRevision(
            id: Self.revisionUUID2,
            createdAt: Date(timeIntervalSinceReferenceDate: 2_345_678.5),
            representations: [
                (Self.pngType, [0x89, 0x50, 0x4E, 0x47]),
                (Self.textType, [0x76, 0x32]),
            ]
        ),
    ]
    let activeRevisionID = RevisionID(rawValue: Self.revisionUUID2)

    let blob = try RevisionStateBlobCodec.encode(
        revisions: revisions,
        activeRevisionID: activeRevisionID
    )
    let decoded = try RevisionStateBlobCodec.decode(blob, canonical: canonical)

    #expect(decoded.revisions == revisions)
    #expect(decoded.activeRevisionID == activeRevisionID)
}

/// Occurrence first/last time and first/last source, pin ordinal, and
/// Content Version survive as validated row scalars (§7.3: "occurrence
/// first/last source, pin ordinal"; docs/05-authority-kernel.md §4).
@Test func roundTripPreservesRowScalars() throws {
    let firstCopiedAt = Date(timeIntervalSinceReferenceDate: 100)
    let lastCopiedAt = Date(timeIntervalSinceReferenceDate: 200.5)

    let occurrence = try RevisionStateBlobCodec.decodeOccurrence(
        firstCopiedAt: firstCopiedAt,
        lastCopiedAt: lastCopiedAt,
        copyCount: 7,
        firstSource: "First App",
        lastSource: "Last App"
    )
    #expect(occurrence.firstCopiedAt == firstCopiedAt)
    #expect(occurrence.lastCopiedAt == lastCopiedAt)
    #expect(occurrence.count == 7)
    #expect(occurrence.firstSource == "First App")
    #expect(occurrence.lastSource == "Last App")

    let unobservedSources = try RevisionStateBlobCodec.decodeOccurrence(
        firstCopiedAt: firstCopiedAt,
        lastCopiedAt: firstCopiedAt,
        copyCount: 1,
        firstSource: nil,
        lastSource: nil
    )
    #expect(unobservedSources.firstSource == nil)
    #expect(unobservedSources.lastSource == nil)

    let contentVersion = try RevisionStateBlobCodec.decodeContentVersion(9)
    #expect(contentVersion.rawValue == 9)

    let pinned = try RevisionStateBlobCodec.decodePinOrdinal(3)
    #expect(pinned == PinOrdinal(rawValue: 3))

    let unpinned = try RevisionStateBlobCodec.decodePinOrdinal(nil)
    #expect(unpinned == nil)
}

/// §4: "Encode ... is deterministic" — encoding one validated value twice
/// yields identical bytes.
@Test func encodeIsDeterministic() throws {
    let revisions = [
        makeRevision(id: Self.revisionUUID1),
        makeRevision(id: Self.revisionUUID2),
    ]
    let activeRevisionID = RevisionID(rawValue: Self.revisionUUID1)

    let first = try RevisionStateBlobCodec.encode(
        revisions: revisions,
        activeRevisionID: activeRevisionID
    )
    let second = try RevisionStateBlobCodec.encode(
        revisions: revisions,
        activeRevisionID: activeRevisionID
    )

    #expect(first == second)
}

}
