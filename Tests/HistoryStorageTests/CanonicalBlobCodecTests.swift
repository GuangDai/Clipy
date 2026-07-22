/// Canonical blob codec gates: encode→decode round trips of valid values
/// (docs/06-cross-cutting.md §7.3) and one rejection test per Part V §4
/// decode check for the Canonical blob (docs/06-cross-cutting.md §7.4;
/// owning spec docs/05-authority-kernel.md §4), plus the §16 failure mapping
/// of the shared `CodecRejection` vocabulary.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct CanonicalBlobCodecTests {

private let customType = "com.example.custom"
private let pngType = "public.png"
private let textType = "public.utf8-plain-text"

private func storedRepresentation(
    _ typeIdentifier: String,
    _ bytes: [UInt8],
    fingerprint: UInt64
) -> StoredCanonicalRepresentationV1 {
    StoredCanonicalRepresentationV1(
        typeIdentifier: typeIdentifier,
        bytes: Data(bytes),
        fingerprint: fingerprint
    )
}

/// A valid multi-representation Canonical value whose fingerprints span the
/// full `UInt64` range (including `UInt64.max`): the wire format must
/// round-trip fingerprint evidence exactly (docs/02-domain.md §2.2).
private func makeCanonical() throws -> CanonicalContent {
    try CanonicalContent(representations: [
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: customType,
                bytes: Data([0x00, 0xFF, 0x7F])
            ),
            fingerprint: ContentFingerprint(rawValue: UInt64.max)
        ),
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: pngType,
                bytes: Data([0x89, 0x50, 0x4E, 0x47])
            ),
            fingerprint: ContentFingerprint(rawValue: 0x1234_5678_9ABC_DEF0)
        ),
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: textType,
                bytes: Data("hello".utf8)
            ),
            fingerprint: ContentFingerprint(rawValue: 42)
        ),
    ])
}

/// Small bounds so the §4 byte/count checks run without large fixtures.
/// Production decode uses the fixed `HistoryLimits.standard` profile
/// (docs/06-cross-cutting.md §2); the codec's `limits` parameter is the seam.
private func makeLimits(
    representations: Int = 2,
    typeIdentifierUTF8Bytes: Int = 16,
    representationBytes: Int = 64,
    captureBytes: Int = 128
) -> HistoryLimits {
    // Force unwrap mirrors `HistoryLimits.standard`: these fixture values
    // satisfy every consistency check, and a violation must fail loudly.
    HistoryLimits(
        maximumRepresentationsPerCaptureOrRevision: representations,
        maximumTypeIdentifierUTF8Bytes: typeIdentifierUTF8Bytes,
        maximumRepresentationBytes: representationBytes,
        maximumCaptureBytes: captureBytes,
        maximumProposedRevisionBytes: 64,
        maximumRevisionsPerItem: 100,
        maximumTotalRevisionBytesPerItem: 256,
        hardMaximumRetainedItems: 5_000,
        userMaximumUnpinnedRange: 1...5_000,
        defaultMaximumUnpinnedItems: 200,
        maximumSourceApplicationObservationUTF8Bytes: 1_024,
        maximumStoredTitleUTF8Bytes: 1_024,
        maximumStoredSearchBodyUTF8Bytes: 262_144,
        pageRowLimitRange: 1...500,
        maximumSearchTermUTF8Bytes: 4_096,
        maximumRegexpPatternCharacters: 512,
        maximumFuzzyQueryCharacters: 256,
        maximumFuzzyTitleBodyPrefixCharacters: 5_000,
        maximumRegexpTitleBodyPrefixCharacters: 1_000,
        maximumBodySearchSnippetCharacters: 322,
        thumbnailDimensionRange: 1...2_048,
        maximumEncodedThumbnailBytes: 16_777_216
    )!
}

// MARK: - Round trips (docs/06-cross-cutting.md §7.3)

@Test func roundTripPreservesContentAndFingerprintEvidence() throws {
    let canonical = try makeCanonical()
    let blob = try CanonicalBlobCodec.encode(canonical)

    let decoded = try CanonicalBlobCodec.decode(blob)

    // Canonical equality ignores fingerprints by design
    // (docs/02-domain.md §2.2/§2.3)...
    #expect(decoded == canonical)
    // ...so the fingerprint evidence is asserted explicitly, at value level
    // and at the byte level.
    #expect(
        decoded.representations.map(\.fingerprint)
            == canonical.representations.map(\.fingerprint)
    )
    #expect(try CanonicalBlobCodec.encode(decoded) == blob)
}

@Test func roundTripPreservesNonASCIITypeIdentifiers() throws {
    // Stable Unicode scalar order (docs/02-domain.md §2.1): 'c' (U+0063)
    // precedes '日' (U+65E5).
    let canonical = try CanonicalContent(representations: [
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: customType,
                bytes: Data([0x01])
            ),
            fingerprint: ContentFingerprint(rawValue: 1)
        ),
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: "com.example.日本語",
                bytes: Data([0x02])
            ),
            fingerprint: ContentFingerprint(rawValue: 2)
        ),
    ])

    let blob = try CanonicalBlobCodec.encode(canonical)
    #expect(try CanonicalBlobCodec.decode(blob) == canonical)
}

@Test func encodeIsDeterministic() throws {
    let canonical = try makeCanonical()
    #expect(try CanonicalBlobCodec.encode(canonical) == CanonicalBlobCodec.encode(canonical))
}

// MARK: - Corruption rejection (docs/06-cross-cutting.md §7.4, Part V §4)

@Test func decodeRejectsMalformedBytes() {
    #expect(throws: CodecRejection.malformedBlob) {
        try CanonicalBlobCodec.decode(Data([0x00, 0x01, 0x02, 0xFF]))
    }
}

@Test func decodeRejectsWellFormedContainerOfWrongShape() throws {
    // A valid container of the wrong shape is malformed — decode is not a
    // blind memberwise conversion (Part V §4).
    let foreign = try JSONEncoder().encode(["not", "a", "canonical", "blob"])
    #expect(throws: CodecRejection.malformedBlob) {
        try CanonicalBlobCodec.decode(foreign)
    }
}

@Test func decodeRejectsUnknownBlobVersion() throws {
    let blob = try CanonicalBlobCodec.encodeWire(
        CanonicalBlobV1(
            formatVersion: 2,
            representations: [storedRepresentation(customType, [0x01], fingerprint: 1)]
        )
    )
    #expect(throws: CodecRejection.unknownBlobVersion(found: 2)) {
        try CanonicalBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsBlobExceedingDecodeEnvelope() {
    // §4: byte/count values are bounded before any large allocation.
    let limits = makeLimits()
    let bound = CanonicalBlobCodec.maximumBlobBytes(limits: limits)
    #expect(
        throws: CodecRejection.blobExceedsDecodeEnvelope(found: bound + 1, bound: bound)
    ) {
        try CanonicalBlobCodec.decode(Data(repeating: 0, count: bound + 1), limits: limits)
    }
}

@Test func decodeRejectsEmptyRepresentationList() throws {
    let blob = try CanonicalBlobCodec.encodeWire(
        CanonicalBlobV1(formatVersion: 1, representations: [])
    )
    #expect(throws: CodecRejection.emptyList) {
        try CanonicalBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsRepresentationCountAboveBound() throws {
    let limits = makeLimits(representations: 2)
    let blob = try CanonicalBlobCodec.encodeWire(
        CanonicalBlobV1(
            formatVersion: 1,
            representations: [
                storedRepresentation("a", [0x01], fingerprint: 1),
                storedRepresentation("b", [0x02], fingerprint: 2),
                storedRepresentation("c", [0x03], fingerprint: 3),
            ]
        )
    )
    #expect(throws: CodecRejection.countExceedsBound(found: 3, bound: 2)) {
        try CanonicalBlobCodec.decode(blob, limits: limits)
    }
}

@Test func decodeRejectsEmptyTypeIdentifier() throws {
    let blob = try CanonicalBlobCodec.encodeWire(
        CanonicalBlobV1(
            formatVersion: 1,
            representations: [storedRepresentation("", [0x01], fingerprint: 1)]
        )
    )
    #expect(throws: CodecRejection.emptyTypeIdentifier) {
        try CanonicalBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsOversizeTypeIdentifier() throws {
    let limits = makeLimits(typeIdentifierUTF8Bytes: 4)
    let blob = try CanonicalBlobCodec.encodeWire(
        CanonicalBlobV1(
            formatVersion: 1,
            representations: [storedRepresentation("abcde", [0x01], fingerprint: 1)]
        )
    )
    #expect(throws: CodecRejection.typeIdentifierExceedsBound(found: 5, bound: 4)) {
        try CanonicalBlobCodec.decode(blob, limits: limits)
    }
}

@Test func decodeRejectsEmptyBytesRepresentation() throws {
    let blob = try CanonicalBlobCodec.encodeWire(
        CanonicalBlobV1(
            formatVersion: 1,
            representations: [storedRepresentation(customType, [], fingerprint: 1)]
        )
    )
    #expect(throws: CodecRejection.emptyBytes(typeIdentifier: customType)) {
        try CanonicalBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsOversizeRepresentationBytes() throws {
    let limits = makeLimits(representationBytes: 4, captureBytes: 8)
    let blob = try CanonicalBlobCodec.encodeWire(
        CanonicalBlobV1(
            formatVersion: 1,
            representations: [storedRepresentation("a", [1, 2, 3, 4, 5], fingerprint: 1)]
        )
    )
    #expect(throws: CodecRejection.representationBytesExceedBound(found: 5, bound: 4)) {
        try CanonicalBlobCodec.decode(blob, limits: limits)
    }
}

@Test func decodeRejectsOversizeTotalBytes() throws {
    // Each representation obeys the per-representation bound; their total
    // exceeds the capture bound (Part VI §2).
    let limits = makeLimits(representationBytes: 8, captureBytes: 9)
    let blob = try CanonicalBlobCodec.encodeWire(
        CanonicalBlobV1(
            formatVersion: 1,
            representations: [
                storedRepresentation("a", [1, 2, 3, 4, 5, 6, 7, 8], fingerprint: 1),
                storedRepresentation("b", [9, 10], fingerprint: 2),
            ]
        )
    )
    #expect(throws: CodecRejection.totalBytesExceedBound(found: 10, bound: 9)) {
        try CanonicalBlobCodec.decode(blob, limits: limits)
    }
}

@Test func decodeRejectsDuplicateTypeIdentifier() throws {
    let blob = try CanonicalBlobCodec.encodeWire(
        CanonicalBlobV1(
            formatVersion: 1,
            representations: [
                storedRepresentation(customType, [0x01], fingerprint: 1),
                storedRepresentation(customType, [0x02], fingerprint: 2),
            ]
        )
    )
    #expect(throws: CodecRejection.duplicateTypeIdentifier(customType)) {
        try CanonicalBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsNonNormalizedOrder() throws {
    let blob = try CanonicalBlobCodec.encodeWire(
        CanonicalBlobV1(
            formatVersion: 1,
            representations: [
                storedRepresentation(textType, [0x01], fingerprint: 1),
                storedRepresentation(pngType, [0x02], fingerprint: 2),
            ]
        )
    )
    #expect(throws: CodecRejection.nonNormalizedOrder) {
        try CanonicalBlobCodec.decode(blob)
    }
}

// MARK: - Failure mapping (docs/05-authority-kernel.md §16)

@Test func rejectionsMapToPersistenceFailures() {
    // Every decode rejection is a corrupt persisted value...
    #expect(CodecRejection.malformedBlob.historyFailure == .persistence(.corruptStoredValue))
    #expect(
        CodecRejection.unknownBlobVersion(found: 2).historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.signatureCoverageMissingEntry(typeIdentifier: "a").historyFailure
            == .persistence(.corruptStoredValue)
    )
    // ...and the encode-side backstop is a storage invariant violation.
    #expect(CodecRejection.encodingFailed.historyFailure == .persistence(.invariantViolation))
}
}
