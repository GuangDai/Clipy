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

private static let pngType = "public.png"
private static let textType = "public.utf8-plain-text"
private static let tiffType = "public.tiff"

private static let revisionUUID1 = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private static let revisionUUID2 = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
private static let foreignUUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!

/// The item's Canonical Content: two normalized representations (PNG sorts
/// before UTF-8 text in stable Unicode scalar order).
private func makeCanonical() throws -> CanonicalContent {
    try CanonicalContent(representations: [
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: pngType,
                bytes: Data([0x89, 0x50])
            ),
            fingerprint: ContentFingerprint(rawValue: 11)
        ),
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: textType,
                bytes: Data([0x68, 0x69])
            ),
            fingerprint: ContentFingerprint(rawValue: 22)
        ),
    ])
}

private func makeRevision(
    id: UUID,
    createdAt: Date = Date(timeIntervalSinceReferenceDate: 1_000),
    representations: [(String, [UInt8])] = [(textType, [0x68, 0x65, 0x6C, 0x6C, 0x6F])]
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

private func storedRepresentation(
    _ typeIdentifier: String,
    _ bytes: [UInt8]
) -> StoredRepresentationV1 {
    StoredRepresentationV1(typeIdentifier: typeIdentifier, bytes: Data(bytes))
}

private func storedRevision(
    _ id: UUID,
    representations: [StoredRepresentationV1]
) -> StoredRevisionV1 {
    StoredRevisionV1(
        id: id,
        createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
        representations: representations
    )
}

/// Serializes a wire value through the production container format so a
/// rejection test crafts its corrupt blob exactly the way production writes
/// valid ones (docs/06-cross-cutting.md §7.4).
private func wireBlob(
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
private func smallLimits(
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
        userMaximumUnpinnedRange: 1...100,
        defaultMaximumUnpinnedItems: 50,
        maximumSourceApplicationObservationUTF8Bytes: maximumSourceApplicationObservationUTF8Bytes,
        maximumStoredTitleUTF8Bytes: 64,
        maximumStoredSearchBodyUTF8Bytes: 128,
        pageRowLimitRange: 1...100,
        maximumSearchTermUTF8Bytes: 64,
        maximumRegexpPatternCharacters: 64,
        maximumFuzzyQueryCharacters: 64,
        maximumFuzzyTitleBodyPrefixCharacters: 64,
        maximumRegexpTitleBodyPrefixCharacters: 64,
        maximumBodySearchSnippetCharacters: 64,
        thumbnailDimensionRange: 1...64,
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
            id: revisionUUID1,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_234_567.25),
            representations: [(textType, [0x76, 0x31])]
        ),
        makeRevision(
            id: revisionUUID2,
            createdAt: Date(timeIntervalSinceReferenceDate: 2_345_678.5),
            representations: [
                (pngType, [0x89, 0x50, 0x4E, 0x47]),
                (textType, [0x76, 0x32]),
            ]
        ),
    ]
    let activeRevisionID = RevisionID(rawValue: revisionUUID2)

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
        makeRevision(id: revisionUUID1),
        makeRevision(id: revisionUUID2),
    ]
    let activeRevisionID = RevisionID(rawValue: revisionUUID1)

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

// MARK: - Corruption rejection (docs/06-cross-cutting.md §7.4)

/// §7.4: foreign bytes are not a decodable v1 container.
@Test func decodeRejectsMalformedBlob() throws {
    let canonical = try makeCanonical()
    #expect(throws: CodecRejection.malformedBlob) {
        try RevisionStateBlobCodec.decode(Data([0x00, 0x01, 0x02]), canonical: canonical)
    }
}

/// §7.4: unknown blob version — only `formatVersion` exactly 1 is valid.
@Test func decodeRejectsUnknownBlobVersion() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(formatVersion: 2, revisions: [], activeRevisionID: nil)
    #expect(throws: CodecRejection.unknownBlobVersion(found: 2)) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: oversize bytes are rejected before any large allocation — a blob
/// larger than the decode envelope cannot be a valid v1 payload.
@Test func decodeRejectsBlobExceedingDecodeEnvelope() throws {
    let canonical = try makeCanonical()
    let limits = smallLimits()
    let envelope = RevisionStateBlobCodec.maximumBlobBytes(limits: limits)
    let blob = Data(count: envelope + 1)
    #expect(
        throws: CodecRejection.blobExceedsDecodeEnvelope(
            found: envelope + 1,
            bound: envelope
        )
    ) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical, limits: limits)
    }
}

/// §7.4: revision-history overflow — the revision count exceeds the Part VI
/// per-item bound.
@Test func decodeRejectsRevisionCountOverflow() throws {
    let canonical = try makeCanonical()
    let limits = smallLimits(maximumRevisionsPerItem: 2)
    let blob = try wireBlob(
        revisions: [
            storedRevision(revisionUUID1, representations: [storedRepresentation(textType, [0x31])]),
            storedRevision(revisionUUID2, representations: [storedRepresentation(textType, [0x32])]),
            storedRevision(foreignUUID, representations: [storedRepresentation(textType, [0x33])]),
        ],
        activeRevisionID: revisionUUID2
    )
    #expect(throws: CodecRejection.countExceedsBound(found: 3, bound: 2)) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical, limits: limits)
    }
}

/// §7.4: revision-history overflow — total revision bytes per item exceed
/// the Part VI bound.
@Test func decodeRejectsTotalRevisionBytesOverflow() throws {
    let canonical = try makeCanonical()
    let limits = smallLimits(
        maximumRevisionsPerItem: 4,
        maximumTotalRevisionBytesPerItem: 128
    )
    let sixtyBytes = [UInt8](repeating: 0x61, count: 60)
    let blob = try wireBlob(
        revisions: [
            storedRevision(revisionUUID1, representations: [storedRepresentation(textType, sixtyBytes)]),
            storedRevision(revisionUUID2, representations: [storedRepresentation(textType, sixtyBytes)]),
            storedRevision(foreignUUID, representations: [storedRepresentation(textType, sixtyBytes)]),
        ],
        activeRevisionID: revisionUUID2
    )
    #expect(throws: CodecRejection.totalBytesExceedBound(found: 180, bound: 128)) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical, limits: limits)
    }
}

/// §7.4: duplicate revision IDs — the decoder does not choose a duplicate.
@Test func decodeRejectsDuplicateRevisionIDs() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(revisionUUID1, representations: [storedRepresentation(textType, [0x31])]),
            storedRevision(revisionUUID1, representations: [storedRepresentation(pngType, [0x32])]),
        ],
        activeRevisionID: revisionUUID1
    )
    #expect(throws: RevisionStateCodecRejection.duplicateRevisionID(revisionUUID1)) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: a non-nil active ID naming no stored revision is corruption.
@Test func decodeRejectsActiveIDNamingNoStoredRevision() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(revisionUUID1, representations: [storedRepresentation(textType, [0x31])]),
        ],
        activeRevisionID: foreignUUID
    )
    #expect(
        throws: RevisionStateCodecRejection.activeRevisionIDNamesNoStoredRevision(foreignUUID)
    ) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: a non-empty revision list with a nil active ID is corruption (D3).
@Test func decodeRejectsNonEmptyRevisionListWithNilActiveID() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(revisionUUID1, representations: [storedRepresentation(textType, [0x31])]),
        ],
        activeRevisionID: nil
    )
    #expect(throws: RevisionStateCodecRejection.nonEmptyRevisionListWithNilActiveID) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: empty revision content — every revision stores a complete,
/// non-empty Effective Content snapshot (docs/02-domain.md §2.5).
@Test func decodeRejectsEmptyRevisionContent() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [storedRevision(revisionUUID1, representations: [])],
        activeRevisionID: revisionUUID1
    )
    #expect(throws: CodecRejection.emptyList) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: revision content whose type identifiers are not strictly increasing
/// in stable Unicode scalar order is not normalized.
@Test func decodeRejectsNonNormalizedRevisionContent() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(
                revisionUUID1,
                representations: [
                    storedRepresentation(textType, [0x31]),
                    storedRepresentation(pngType, [0x32]),
                ]
            ),
        ],
        activeRevisionID: revisionUUID1
    )
    #expect(throws: CodecRejection.nonNormalizedOrder) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: a repeated type identifier inside one revision is a duplicate, not
/// a choice (docs/02-domain.md §2.1).
@Test func decodeRejectsDuplicateRevisionTypeIdentifier() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(
                revisionUUID1,
                representations: [
                    storedRepresentation(pngType, [0x31]),
                    storedRepresentation(pngType, [0x32]),
                ]
            ),
        ],
        activeRevisionID: revisionUUID1
    )
    #expect(throws: CodecRejection.duplicateTypeIdentifier(pngType)) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: revision content containing a non-Canonical representation type.
@Test func decodeRejectsNonCanonicalRevisionType() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(
                revisionUUID1,
                representations: [storedRepresentation(tiffType, [0x31])]
            ),
        ],
        activeRevisionID: revisionUUID1
    )
    #expect(throws: RevisionStateCodecRejection.nonCanonicalRevisionType(tiffType)) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: a revision representation with empty bytes.
@Test func decodeRejectsEmptyRevisionRepresentationBytes() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(
                revisionUUID1,
                representations: [storedRepresentation(textType, [])]
            ),
        ],
        activeRevisionID: revisionUUID1
    )
    #expect(throws: CodecRejection.emptyBytes(typeIdentifier: textType)) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: unbounded byte values — one representation exceeds the Part VI
/// per-representation byte bound.
@Test func decodeRejectsOversizeRevisionRepresentationBytes() throws {
    let canonical = try makeCanonical()
    let limits = smallLimits(maximumRepresentationBytes: 64)
    let blob = try wireBlob(
        revisions: [
            storedRevision(
                revisionUUID1,
                representations: [
                    storedRepresentation(textType, [UInt8](repeating: 0x61, count: 100))
                ]
            ),
        ],
        activeRevisionID: revisionUUID1
    )
    #expect(
        throws: CodecRejection.representationBytesExceedBound(found: 100, bound: 64)
    ) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical, limits: limits)
    }
}

/// §7.4: unbounded byte values — one revision's total bytes exceed the Part
/// VI proposed-revision bound.
@Test func decodeRejectsPerRevisionByteOverflow() throws {
    let canonical = try makeCanonical()
    let limits = smallLimits(maximumProposedRevisionBytes: 64)
    let fortyBytes = [UInt8](repeating: 0x61, count: 40)
    let blob = try wireBlob(
        revisions: [
            storedRevision(
                revisionUUID1,
                representations: [
                    storedRepresentation(pngType, fortyBytes),
                    storedRepresentation(textType, fortyBytes),
                ]
            ),
        ],
        activeRevisionID: revisionUUID1
    )
    #expect(throws: CodecRejection.totalBytesExceedBound(found: 80, bound: 64)) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical, limits: limits)
    }
}

/// §7.4: unbounded count values — one revision's representation count
/// exceeds the Part VI per-capture/revision bound.
@Test func decodeRejectsRevisionRepresentationCountOverflow() throws {
    let canonical = try makeCanonical()
    let limits = smallLimits(maximumRepresentationsPerCaptureOrRevision: 4)
    let blob = try wireBlob(
        revisions: [
            storedRevision(
                revisionUUID1,
                representations: [
                    storedRepresentation("a", [0x31]),
                    storedRepresentation("b", [0x32]),
                    storedRepresentation("c", [0x33]),
                    storedRepresentation("d", [0x34]),
                    storedRepresentation("e", [0x35]),
                ]
            ),
        ],
        activeRevisionID: revisionUUID1
    )
    #expect(throws: CodecRejection.countExceedsBound(found: 5, bound: 4)) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical, limits: limits)
    }
}

/// §7.4: an empty type identifier inside revision content.
@Test func decodeRejectsEmptyRevisionTypeIdentifier() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(
                revisionUUID1,
                representations: [storedRepresentation("", [0x31])]
            ),
        ],
        activeRevisionID: revisionUUID1
    )
    #expect(throws: CodecRejection.emptyTypeIdentifier) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: a type identifier exceeding the Part VI UTF-8 byte bound.
@Test func decodeRejectsOversizeRevisionTypeIdentifier() throws {
    let canonical = try makeCanonical()
    let limits = smallLimits(maximumTypeIdentifierUTF8Bytes: 64)
    let oversized = String(repeating: "t", count: 65)
    let blob = try wireBlob(
        revisions: [
            storedRevision(
                revisionUUID1,
                representations: [storedRepresentation(oversized, [0x31])]
            ),
        ],
        activeRevisionID: revisionUUID1
    )
    #expect(
        throws: CodecRejection.typeIdentifierExceedsBound(found: 65, bound: 64)
    ) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical, limits: limits)
    }
}

/// §7.4: a zero Content Version (docs/05-authority-kernel.md §3.1: always at
/// least 1).
@Test func decodeRejectsZeroContentVersion() {
    #expect(throws: RevisionStateCodecRejection.invalidContentVersion(found: 0)) {
        try RevisionStateBlobCodec.decodeContentVersion(0)
    }
}

/// §7.4: invalid occurrence values — a zero copy count; a retained item
/// exists only through at least one accepted capture.
@Test func decodeRejectsZeroCopyCount() {
    #expect(throws: RevisionStateCodecRejection.zeroCopyCount) {
        try RevisionStateBlobCodec.decodeOccurrence(
            firstCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
            copyCount: 0,
            firstSource: nil,
            lastSource: nil
        )
    }
}

/// §7.4: invalid occurrence values — recency precedes the first copy (D11
/// monotone occurrence).
@Test func decodeRejectsOccurrenceRecencyPrecedingFirstCopy() {
    #expect(throws: RevisionStateCodecRejection.lastCopiedAtPrecedesFirstCopiedAt) {
        try RevisionStateBlobCodec.decodeOccurrence(
            firstCopiedAt: Date(timeIntervalSinceReferenceDate: 200),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
            copyCount: 2,
            firstSource: nil,
            lastSource: nil
        )
    }
}

/// §7.4: invalid occurrence values — a source-application observation beyond
/// the Part VI UTF-8 byte bound.
@Test func decodeRejectsOversizeSourceObservation() {
    let limits = smallLimits(maximumSourceApplicationObservationUTF8Bytes: 16)
    #expect(
        throws: RevisionStateCodecRejection.sourceObservationExceedsBound(
            found: 17,
            bound: 16
        )
    ) {
        try RevisionStateBlobCodec.decodeOccurrence(
            firstCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
            copyCount: 1,
            firstSource: String(repeating: "s", count: 17),
            lastSource: nil,
            limits: limits
        )
    }
}

/// §7.4: a negative pin ordinal is corruption.
@Test func decodeRejectsNegativePinOrdinal() {
    #expect(throws: RevisionStateCodecRejection.negativePinOrdinal(found: -1)) {
        try RevisionStateBlobCodec.decodePinOrdinal(-1)
    }
}

/// §16/§7.4: every decode rejection maps to
/// `.persistence(.corruptStoredValue)` at the storage boundary.
@Test func rejectionsMapToCorruptStoredValue() {
    #expect(
        RevisionStateCodecRejection.duplicateRevisionID(revisionUUID1).historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        RevisionStateCodecRejection.activeRevisionIDNamesNoStoredRevision(foreignUUID)
            .historyFailure == .persistence(.corruptStoredValue)
    )
    #expect(
        RevisionStateCodecRejection.nonEmptyRevisionListWithNilActiveID.historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        RevisionStateCodecRejection.nonCanonicalRevisionType(tiffType).historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        RevisionStateCodecRejection.invalidContentVersion(found: 0).historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        RevisionStateCodecRejection.zeroCopyCount.historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        RevisionStateCodecRejection.lastCopiedAtPrecedesFirstCopiedAt.historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        RevisionStateCodecRejection.sourceObservationExceedsBound(found: 17, bound: 16)
            .historyFailure == .persistence(.corruptStoredValue)
    )
    #expect(
        RevisionStateCodecRejection.negativePinOrdinal(found: -1).historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.unknownBlobVersion(found: 2).historyFailure
            == .persistence(.corruptStoredValue)
    )
}
}
