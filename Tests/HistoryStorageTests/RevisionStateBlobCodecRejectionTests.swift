/// Corruption-rejection proofs (§7.4), part 1.
/// Split out of RevisionStateBlobCodecTests.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import Testing
import HistoryCore
import HistoryDomain
@testable import HistoryStorage

extension RevisionStateBlobCodecTests {
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
            storedRevision(Self.revisionUUID1, representations: [storedRepresentation(Self.textType, [0x31])]),
            storedRevision(Self.revisionUUID2, representations: [storedRepresentation(Self.textType, [0x32])]),
            storedRevision(Self.foreignUUID, representations: [storedRepresentation(Self.textType, [0x33])]),
        ],
        activeRevisionID: Self.revisionUUID2
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
            storedRevision(Self.revisionUUID1, representations: [storedRepresentation(Self.textType, sixtyBytes)]),
            storedRevision(Self.revisionUUID2, representations: [storedRepresentation(Self.textType, sixtyBytes)]),
            storedRevision(Self.foreignUUID, representations: [storedRepresentation(Self.textType, sixtyBytes)]),
        ],
        activeRevisionID: Self.revisionUUID2
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
            storedRevision(Self.revisionUUID1, representations: [storedRepresentation(Self.textType, [0x31])]),
            storedRevision(Self.revisionUUID1, representations: [storedRepresentation(Self.pngType, [0x32])]),
        ],
        activeRevisionID: Self.revisionUUID1
    )
    #expect(throws: CodecRejection.duplicateRevisionID(Self.revisionUUID1)) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: a non-nil active ID naming no stored revision is corruption.
@Test func decodeRejectsActiveIDNamingNoStoredRevision() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(Self.revisionUUID1, representations: [storedRepresentation(Self.textType, [0x31])]),
        ],
        activeRevisionID: Self.foreignUUID
    )
    #expect(
        throws: CodecRejection.activeRevisionIDNamesNoStoredRevision(Self.foreignUUID)
    ) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4/D3: a non-nil active ID is corruption even when the stored
/// revision list is completely empty.
@Test func decodeRejectsEmptyRevisionListWithNonNilActiveID() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [],
        activeRevisionID: Self.foreignUUID
    )
    #expect(
        throws: CodecRejection.activeRevisionIDNamesNoStoredRevision(
            Self.foreignUUID
        )
    ) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §4: every decoded revision timestamp must be a finite value before it
/// enters Domain ordering. The wire-value seam is intentional here because
/// JSONEncoder rejects non-conforming floating-point dates before it can
/// serialize this otherwise structurally valid corruption fixture.
@Test func decodeRejectsNonFiniteRevisionCreationDates() throws {
    let canonical = try makeCanonical()
    for interval in [Double.nan, Double.infinity, -Double.infinity] {
        let wire = RevisionStateBlobV1(
            formatVersion: 1,
            revisions: [storedRevision(
                Self.revisionUUID1,
                createdAt: Date(timeIntervalSinceReferenceDate: interval),
                representations: [storedRepresentation(Self.textType, [0x31])]
            )],
            activeRevisionID: Self.revisionUUID1
        )
        #expect(
            throws: CodecRejection.nonFiniteRevisionCreatedAt(
                Self.revisionUUID1
            )
        ) {
            try RevisionStateBlobCodec.decodeValidatedWire(
                wire,
                canonical: canonical
            )
        }
    }
}

/// §7.4: a non-empty revision list with a nil active ID is corruption (D3).
@Test func decodeRejectsNonEmptyRevisionListWithNilActiveID() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(Self.revisionUUID1, representations: [storedRepresentation(Self.textType, [0x31])]),
        ],
        activeRevisionID: nil
    )
    #expect(throws: CodecRejection.nonEmptyRevisionListWithNilActiveID) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: empty revision content — every revision stores a complete,
/// non-empty Effective Content snapshot (docs/02-domain.md §2.5).
@Test func decodeRejectsEmptyRevisionContent() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [storedRevision(Self.revisionUUID1, representations: [])],
        activeRevisionID: Self.revisionUUID1
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
                Self.revisionUUID1,
                representations: [
                    storedRepresentation(Self.textType, [0x31]),
                    storedRepresentation(Self.pngType, [0x32]),
                ]
            ),
        ],
        activeRevisionID: Self.revisionUUID1
    )
    #expect(throws: CodecRejection.nonNormalizedOrder) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: a repeated type identifier inside one revision is a duplicate, not
/// a choice (docs/02-domain.md §2.1).
}
