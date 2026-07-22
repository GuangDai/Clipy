/// Effective type identifiers blob codec gates: encode→decode round trips of
/// valid values (docs/06-cross-cutting.md §7.3) and one rejection test per
/// Part V §4 decode check — the blob must decode to a valid versioned
/// sorted-unique non-empty list (docs/06-cross-cutting.md §7.4; owning spec
/// docs/05-authority-kernel.md §4).
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// A valid sorted, unique, non-empty projection list (Part V §15).
private let sortedIdentifiers = [
    "com.example.custom",
    "public.png",
    "public.utf8-plain-text",
]

/// Small bounds so the §4 byte/count checks run without large fixtures.
/// Production decode uses the fixed `HistoryLimits.standard` profile
/// (docs/06-cross-cutting.md §2); the codec's `limits` parameter is the seam.
private func makeLimits(
    representations: Int = 2,
    typeIdentifierUTF8Bytes: Int = 16
) -> HistoryLimits {
    // Force unwrap mirrors `HistoryLimits.standard`: these fixture values
    // satisfy every consistency check, and a violation must fail loudly.
    HistoryLimits(
        maximumRepresentationsPerCaptureOrRevision: representations,
        maximumTypeIdentifierUTF8Bytes: typeIdentifierUTF8Bytes,
        maximumRepresentationBytes: 64,
        maximumCaptureBytes: 128,
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

@Test func roundTripPreservesSortedUniqueList() throws {
    let blob = try EffectiveTypeIdentifiersBlobCodec.encode(sortedIdentifiers)

    let decoded = try EffectiveTypeIdentifiersBlobCodec.decode(blob)

    #expect(decoded == sortedIdentifiers)
    #expect(try EffectiveTypeIdentifiersBlobCodec.encode(decoded) == blob)
}

@Test func roundTripPreservesSingleIdentifierList() throws {
    let identifiers = ["public.utf8-plain-text"]
    let blob = try EffectiveTypeIdentifiersBlobCodec.encode(identifiers)
    #expect(try EffectiveTypeIdentifiersBlobCodec.decode(blob) == identifiers)
}

@Test func roundTripPreservesNonASCIIIdentifiers() throws {
    // Stable Unicode scalar order (docs/02-domain.md §2.1): 'c' (U+0063)
    // precedes '日' (U+65E5).
    let identifiers = ["com.example.custom", "com.example.日本語"]
    let blob = try EffectiveTypeIdentifiersBlobCodec.encode(identifiers)
    #expect(try EffectiveTypeIdentifiersBlobCodec.decode(blob) == identifiers)
}

@Test func encodeIsDeterministic() throws {
    #expect(
        try EffectiveTypeIdentifiersBlobCodec.encode(sortedIdentifiers)
            == EffectiveTypeIdentifiersBlobCodec.encode(sortedIdentifiers)
    )
}

// MARK: - Corruption rejection (docs/06-cross-cutting.md §7.4, Part V §4)

@Test func decodeRejectsMalformedBytes() {
    #expect(throws: CodecRejection.malformedBlob) {
        try EffectiveTypeIdentifiersBlobCodec.decode(Data([0x00, 0x01, 0x02, 0xFF]))
    }
}

@Test func decodeRejectsWellFormedContainerOfWrongShape() {
    // A valid container missing the required members is malformed, not a
    // blind memberwise default (Part V §4).
    let foreign = Data(#"{"formatVersion": 1}"#.utf8)
    #expect(throws: CodecRejection.malformedBlob) {
        try EffectiveTypeIdentifiersBlobCodec.decode(foreign)
    }
}

@Test func decodeRejectsUnknownBlobVersion() throws {
    let blob = try EffectiveTypeIdentifiersBlobCodec.encodeWire(
        EffectiveTypeIdentifiersBlobV1(formatVersion: 2, typeIdentifiers: ["a"])
    )
    #expect(throws: CodecRejection.unknownBlobVersion(found: 2)) {
        try EffectiveTypeIdentifiersBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsBlobExceedingDecodeEnvelope() {
    // §4: byte/count values are bounded before any large allocation.
    let limits = makeLimits()
    let bound = EffectiveTypeIdentifiersBlobCodec.maximumBlobBytes(limits: limits)
    #expect(
        throws: CodecRejection.blobExceedsDecodeEnvelope(found: bound + 1, bound: bound)
    ) {
        try EffectiveTypeIdentifiersBlobCodec.decode(
            Data(repeating: 0, count: bound + 1),
            limits: limits
        )
    }
}

@Test func decodeRejectsEmptyIdentifierList() throws {
    let blob = try EffectiveTypeIdentifiersBlobCodec.encodeWire(
        EffectiveTypeIdentifiersBlobV1(formatVersion: 1, typeIdentifiers: [])
    )
    #expect(throws: CodecRejection.emptyList) {
        try EffectiveTypeIdentifiersBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsIdentifierCountAboveBound() throws {
    let limits = makeLimits(representations: 2)
    let blob = try EffectiveTypeIdentifiersBlobCodec.encodeWire(
        EffectiveTypeIdentifiersBlobV1(
            formatVersion: 1,
            typeIdentifiers: ["a", "b", "c"]
        )
    )
    #expect(throws: CodecRejection.countExceedsBound(found: 3, bound: 2)) {
        try EffectiveTypeIdentifiersBlobCodec.decode(blob, limits: limits)
    }
}

@Test func decodeRejectsEmptyTypeIdentifier() throws {
    let blob = try EffectiveTypeIdentifiersBlobCodec.encodeWire(
        EffectiveTypeIdentifiersBlobV1(formatVersion: 1, typeIdentifiers: [""])
    )
    #expect(throws: CodecRejection.emptyTypeIdentifier) {
        try EffectiveTypeIdentifiersBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsOversizeTypeIdentifier() throws {
    let limits = makeLimits(typeIdentifierUTF8Bytes: 4)
    let blob = try EffectiveTypeIdentifiersBlobCodec.encodeWire(
        EffectiveTypeIdentifiersBlobV1(formatVersion: 1, typeIdentifiers: ["abcde"])
    )
    #expect(throws: CodecRejection.typeIdentifierExceedsBound(found: 5, bound: 4)) {
        try EffectiveTypeIdentifiersBlobCodec.decode(blob, limits: limits)
    }
}

@Test func decodeRejectsDuplicateTypeIdentifier() throws {
    let blob = try EffectiveTypeIdentifiersBlobCodec.encodeWire(
        EffectiveTypeIdentifiersBlobV1(formatVersion: 1, typeIdentifiers: ["a", "a"])
    )
    #expect(throws: CodecRejection.duplicateTypeIdentifier("a")) {
        try EffectiveTypeIdentifiersBlobCodec.decode(blob)
    }
}

@Test func decodeRejectsNonNormalizedOrder() throws {
    let blob = try EffectiveTypeIdentifiersBlobCodec.encodeWire(
        EffectiveTypeIdentifiersBlobV1(
            formatVersion: 1,
            typeIdentifiers: ["public.utf8-plain-text", "public.png"]
        )
    )
    #expect(throws: CodecRejection.nonNormalizedOrder) {
        try EffectiveTypeIdentifiersBlobCodec.decode(blob)
    }
}
