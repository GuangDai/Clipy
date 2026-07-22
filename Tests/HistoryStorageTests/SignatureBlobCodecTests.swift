/// Signature blob codec gates: encode→decode round trips of valid values
/// (docs/06-cross-cutting.md §7.3), one rejection test per Part V §4 decode
/// check for the signature blob, and the §4 bidirectional
/// fingerprint/signature coverage checks against the Canonical blob
/// (docs/06-cross-cutting.md §7.4; owning spec docs/05-authority-kernel.md
/// §4).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct SignatureBlobCodecTests {

private let customType = "com.example.custom"
private let pngType = "public.png"
private let textType = "public.utf8-plain-text"

/// The same valid Canonical value the Canonical blob tests use, including a
/// full-range `UInt64` fingerprint.
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

/// The valid signature entries deriving one-to-one from `canonical`
/// (Part V §6.1 step 6): same type identifier, same fingerprint evidence,
/// `byteCount` equal to the representation's byte length.
private func signatureEntries(for canonical: CanonicalContent) -> [ContentSignatureEntry] {
    canonical.representations.map { representation in
        ContentSignatureEntry(
            typeIdentifier: representation.content.typeIdentifier,
            fingerprint: representation.fingerprint,
            byteCount: representation.content.bytes.count
        )
    }
}

private func storedEntry(
    _ typeIdentifier: String,
    fingerprint: UInt64,
    byteCount: Int
) -> StoredSignatureEntryV1 {
    StoredSignatureEntryV1(
        typeIdentifier: typeIdentifier,
        fingerprint: fingerprint,
        byteCount: byteCount
    )
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

@Test func roundTripPreservesSignatureEntries() throws {
    let entries = signatureEntries(for: try makeCanonical())
    let blob = try SignatureBlobCodec.encode(entries)

    let decoded = try SignatureBlobCodec.decode(blob)

    #expect(decoded == entries)
    #expect(try SignatureBlobCodec.encode(decoded) == blob)
}

@Test func encodeIsDeterministic() throws {
    let entries = signatureEntries(for: try makeCanonical())
    #expect(try SignatureBlobCodec.encode(entries) == SignatureBlobCodec.encode(entries))
}

@Test func canonicalAndSignatureBlobsValidateCoverageTogether() throws {
    // The §4 coverage check closes over both blobs of one row: Canonical
    // bytes/fingerprints and signature metadata round-trip and agree
    // (Part VI §7.3: signatures survive restart).
    let canonical = try makeCanonical()
    let decodedCanonical = try CanonicalBlobCodec.decode(
        CanonicalBlobCodec.encode(canonical)
    )
    let decodedEntries = try SignatureBlobCodec.decode(
        SignatureBlobCodec.encode(signatureEntries(for: canonical))
    )
    try SignatureBlobCodec.validateCoverage(
        canonical: decodedCanonical,
        entries: decodedEntries
    )
}

// MARK: - Corruption rejection (docs/06-cross-cutting.md §7.4, Part V §4)

@Test func decodeRejectsMalformedBytes() {
    #expect(throws: CodecRejection.malformedBlob) {
        try SignatureBlobCodec.decode(Data([0x00, 0x01, 0x02, 0xFF]))
    }
}

@Test func decodeRejectsWellFormedContainerOfWrongShape() {
    // A valid container missing the required members is malformed, not a
    // blind memberwise default (Part V §4).
    let foreign = Data(#"{"formatVersion": 1}"#.utf8)
    #expect(throws: CodecRejection.malformedBlob) {
        try SignatureBlobCodec.decode(foreign)
    }
}

@Test func decodeRejectsUnknownBlobVersion() throws {
    let blob = try SignatureBlobCodec.encodeWire(
        SignatureBlobV1(
            formatVersion: 0,
            entries: [storedEntry(customType, fingerprint: 1, byteCount: 1)]
        )
    )
    #expect(throws: CodecRejection.unknownBlobVersion(found: 0)) {
        try SignatureBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsBlobExceedingDecodeEnvelope() {
    // §4: byte/count values are bounded before any large allocation.
    let limits = makeLimits()
    let bound = SignatureBlobCodec.maximumBlobBytes(limits: limits)
    #expect(
        throws: CodecRejection.blobExceedsDecodeEnvelope(found: bound + 1, bound: bound)
    ) {
        try SignatureBlobCodec.decode(Data(repeating: 0, count: bound + 1), limits: limits)
    }
}

@Test func decodeRejectsEmptyEntryList() throws {
    let blob = try SignatureBlobCodec.encodeWire(
        SignatureBlobV1(formatVersion: 1, entries: [])
    )
    #expect(throws: CodecRejection.emptyList) {
        try SignatureBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsEntryCountAboveBound() throws {
    let limits = makeLimits(representations: 2)
    let blob = try SignatureBlobCodec.encodeWire(
        SignatureBlobV1(
            formatVersion: 1,
            entries: [
                storedEntry("a", fingerprint: 1, byteCount: 1),
                storedEntry("b", fingerprint: 2, byteCount: 2),
                storedEntry("c", fingerprint: 3, byteCount: 3),
            ]
        )
    )
    #expect(throws: CodecRejection.countExceedsBound(found: 3, bound: 2)) {
        try SignatureBlobCodec.decode(blob, limits: limits)
    }
}

@Test func decodeRejectsEmptyTypeIdentifier() throws {
    let blob = try SignatureBlobCodec.encodeWire(
        SignatureBlobV1(
            formatVersion: 1,
            entries: [storedEntry("", fingerprint: 1, byteCount: 1)]
        )
    )
    #expect(throws: CodecRejection.emptyTypeIdentifier) {
        try SignatureBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsOversizeTypeIdentifier() throws {
    let limits = makeLimits(typeIdentifierUTF8Bytes: 4)
    let blob = try SignatureBlobCodec.encodeWire(
        SignatureBlobV1(
            formatVersion: 1,
            entries: [storedEntry("abcde", fingerprint: 1, byteCount: 1)]
        )
    )
    #expect(throws: CodecRejection.typeIdentifierExceedsBound(found: 5, bound: 4)) {
        try SignatureBlobCodec.decode(blob, limits: limits)
    }
}

@Test func decodeRejectsNonPositiveByteCount() throws {
    let zeroBlob = try SignatureBlobCodec.encodeWire(
        SignatureBlobV1(
            formatVersion: 1,
            entries: [storedEntry(customType, fingerprint: 1, byteCount: 0)]
        )
    )
    #expect(throws: CodecRejection.nonPositiveSignatureByteCount(found: 0)) {
        try SignatureBlobCodec.decode(zeroBlob)
    }

    let negativeBlob = try SignatureBlobCodec.encodeWire(
        SignatureBlobV1(
            formatVersion: 1,
            entries: [storedEntry(customType, fingerprint: 1, byteCount: -1)]
        )
    )
    #expect(throws: CodecRejection.nonPositiveSignatureByteCount(found: -1)) {
        try SignatureBlobCodec.decode(negativeBlob)
    }
}

@Test func decodeRejectsByteCountAboveBound() throws {
    let limits = makeLimits(representationBytes: 4)
    let blob = try SignatureBlobCodec.encodeWire(
        SignatureBlobV1(
            formatVersion: 1,
            entries: [storedEntry("a", fingerprint: 1, byteCount: 5)]
        )
    )
    #expect(throws: CodecRejection.signatureByteCountExceedsBound(found: 5, bound: 4)) {
        try SignatureBlobCodec.decode(blob, limits: limits)
    }
}

@Test func decodeRejectsDuplicateTypeIdentifier() throws {
    let blob = try SignatureBlobCodec.encodeWire(
        SignatureBlobV1(
            formatVersion: 1,
            entries: [
                storedEntry("a", fingerprint: 1, byteCount: 1),
                storedEntry("a", fingerprint: 2, byteCount: 2),
            ]
        )
    )
    #expect(throws: CodecRejection.duplicateTypeIdentifier("a")) {
        try SignatureBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsNonNormalizedOrder() throws {
    let blob = try SignatureBlobCodec.encodeWire(
        SignatureBlobV1(
            formatVersion: 1,
            entries: [
                storedEntry(textType, fingerprint: 1, byteCount: 1),
                storedEntry(pngType, fingerprint: 2, byteCount: 2),
            ]
        )
    )
    #expect(throws: CodecRejection.nonNormalizedOrder) {
        try SignatureBlobCodec.decode(blob)
    }
}

// MARK: - Bidirectional coverage (docs/05-authority-kernel.md §4)

@Test func coverageAcceptsMatchingCanonicalAndEntries() throws {
    let canonical = try makeCanonical()
    try SignatureBlobCodec.validateCoverage(
        canonical: canonical,
        entries: signatureEntries(for: canonical)
    )
}

@Test func coverageRejectsCountMismatch() throws {
    let canonical = try makeCanonical()
    let entries = Array(signatureEntries(for: canonical).dropLast())
    #expect(
        throws: CodecRejection.signatureCoverageCountMismatch(
            canonicalCount: 3,
            signatureCount: 2
        )
    ) {
        try SignatureBlobCodec.validateCoverage(canonical: canonical, entries: entries)
    }
}

@Test func coverageRejectsOrphanedEntry() throws {
    // §4: every signature entry must correspond to a Canonical
    // representation — no orphan entries.
    let canonical = try makeCanonical()
    var entries = signatureEntries(for: canonical)
    entries[2] = ContentSignatureEntry(
        typeIdentifier: "zzz.orphan",
        fingerprint: ContentFingerprint(rawValue: 9),
        byteCount: 1
    )
    #expect(
        throws: CodecRejection.signatureCoverageOrphanedEntry(typeIdentifier: "zzz.orphan")
    ) {
        try SignatureBlobCodec.validateCoverage(canonical: canonical, entries: entries)
    }
}

@Test func coverageRejectsMissingEntry() throws {
    // §4: every Canonical representation must have a signature entry. Equal
    // count, no orphan, but one Canonical type uncovered — a decoded list can
    // never look like this (duplicates are rejected at decode), so the
    // fixture hands `validateCoverage` a raw list with a duplicated type.
    let canonical = try makeCanonical()
    let entries = signatureEntries(for: canonical)
    let duplicated = [entries[0], entries[0], entries[1]]
    #expect(
        throws: CodecRejection.signatureCoverageMissingEntry(typeIdentifier: textType)
    ) {
        try SignatureBlobCodec.validateCoverage(canonical: canonical, entries: duplicated)
    }
}

@Test func coverageRejectsFingerprintMismatch() throws {
    // Coverage requires the two durable copies of the fingerprint evidence
    // to agree (§4); fingerprint correctness itself is not re-verified (D7).
    let canonical = try makeCanonical()
    var entries = signatureEntries(for: canonical)
    entries[0] = ContentSignatureEntry(
        typeIdentifier: customType,
        fingerprint: ContentFingerprint(rawValue: 0xDEAD_BEEF),
        byteCount: entries[0].byteCount
    )
    #expect(
        throws: CodecRejection.signatureCoverageFingerprintMismatch(
            typeIdentifier: customType
        )
    ) {
        try SignatureBlobCodec.validateCoverage(canonical: canonical, entries: entries)
    }
}

@Test func coverageRejectsByteCountMismatch() throws {
    let canonical = try makeCanonical()
    var entries = signatureEntries(for: canonical)
    entries[1] = ContentSignatureEntry(
        typeIdentifier: pngType,
        fingerprint: entries[1].fingerprint,
        byteCount: entries[1].byteCount + 1
    )
    #expect(
        throws: CodecRejection.signatureCoverageByteCountMismatch(typeIdentifier: pngType)
    ) {
        try SignatureBlobCodec.validateCoverage(canonical: canonical, entries: entries)
    }
}
}
