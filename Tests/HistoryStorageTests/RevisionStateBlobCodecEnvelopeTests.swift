/// Corruption-rejection proofs (§7.4), part 2: per-revision envelope limits.
/// Split out of RevisionStateBlobCodecTests.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import Testing
import HistoryCore
import HistoryDomain
@testable import HistoryStorage

extension RevisionStateBlobCodecTests {
@Test func decodeRejectsDuplicateRevisionTypeIdentifier() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(
                Self.revisionUUID1,
                representations: [
                    storedRepresentation(Self.pngType, [0x31]),
                    storedRepresentation(Self.pngType, [0x32]),
                ]
            ),
        ],
        activeRevisionID: Self.revisionUUID1
    )
    #expect(throws: CodecRejection.duplicateTypeIdentifier(Self.pngType)) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: revision content containing a non-Canonical representation type.
@Test func decodeRejectsNonCanonicalRevisionType() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(
                Self.revisionUUID1,
                representations: [storedRepresentation(Self.tiffType, [0x31])]
            ),
        ],
        activeRevisionID: Self.revisionUUID1
    )
    #expect(throws: CodecRejection.nonCanonicalRevisionType(Self.tiffType)) {
        try RevisionStateBlobCodec.decode(blob, canonical: canonical)
    }
}

/// §7.4: a revision representation with empty bytes.
@Test func decodeRejectsEmptyRevisionRepresentationBytes() throws {
    let canonical = try makeCanonical()
    let blob = try wireBlob(
        revisions: [
            storedRevision(
                Self.revisionUUID1,
                representations: [storedRepresentation(Self.textType, [])]
            ),
        ],
        activeRevisionID: Self.revisionUUID1
    )
    #expect(throws: CodecRejection.emptyBytes(typeIdentifier: Self.textType)) {
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
                Self.revisionUUID1,
                representations: [
                    storedRepresentation(Self.textType, [UInt8](repeating: 0x61, count: 100))
                ]
            ),
        ],
        activeRevisionID: Self.revisionUUID1
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
                Self.revisionUUID1,
                representations: [
                    storedRepresentation(Self.pngType, fortyBytes),
                    storedRepresentation(Self.textType, fortyBytes),
                ]
            ),
        ],
        activeRevisionID: Self.revisionUUID1
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
                Self.revisionUUID1,
                representations: [
                    storedRepresentation("a", [0x31]),
                    storedRepresentation("b", [0x32]),
                    storedRepresentation("c", [0x33]),
                    storedRepresentation("d", [0x34]),
                    storedRepresentation("e", [0x35]),
                ]
            ),
        ],
        activeRevisionID: Self.revisionUUID1
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
                Self.revisionUUID1,
                representations: [storedRepresentation("", [0x31])]
            ),
        ],
        activeRevisionID: Self.revisionUUID1
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
                Self.revisionUUID1,
                representations: [storedRepresentation(oversized, [0x31])]
            ),
        ],
        activeRevisionID: Self.revisionUUID1
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
    #expect(throws: CodecRejection.invalidContentVersion(found: 0)) {
        try RevisionStateBlobCodec.decodeContentVersion(0)
    }
}

/// §7.4: invalid occurrence values — a zero copy count; a retained item
/// exists only through at least one accepted capture.
@Test func decodeRejectsZeroCopyCount() {
    #expect(throws: CodecRejection.zeroCopyCount) {
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
    #expect(throws: CodecRejection.lastCopiedAtPrecedesFirstCopiedAt) {
        try RevisionStateBlobCodec.decodeOccurrence(
            firstCopiedAt: Date(timeIntervalSinceReferenceDate: 200),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
            copyCount: 2,
            firstSource: nil,
            lastSource: nil
        )
    }
}

/// §4: a first-copy timestamp must be finite; NaN and either infinity are
/// corruption even when the last-copy timestamp would otherwise compare as
/// monotone.
@Test func decodeRejectsNonFiniteFirstCopiedAt() {
    for interval in [Double.nan, Double.infinity, -Double.infinity] {
        #expect(throws: CodecRejection.nonFiniteFirstCopiedAt) {
            try RevisionStateBlobCodec.decodeOccurrence(
                firstCopiedAt: Date(timeIntervalSinceReferenceDate: interval),
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 200),
                copyCount: 1,
                firstSource: nil,
                lastSource: nil
            )
        }
    }
}

/// §4: a last-copy timestamp must be finite before recency ordering or
/// cursor materialization can consume it.
@Test func decodeRejectsNonFiniteLastCopiedAt() {
    for interval in [Double.nan, Double.infinity, -Double.infinity] {
        #expect(throws: CodecRejection.nonFiniteLastCopiedAt) {
            try RevisionStateBlobCodec.decodeOccurrence(
                firstCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: interval),
                copyCount: 1,
                firstSource: nil,
                lastSource: nil
            )
        }
    }
}

/// §7.4: invalid occurrence values — a source-application observation beyond
/// the Part VI UTF-8 byte bound.
@Test func decodeRejectsOversizeSourceObservation() {
    let limits = smallLimits(maximumSourceApplicationObservationUTF8Bytes: 16)
    #expect(
        throws: CodecRejection.sourceObservationExceedsBound(
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
    #expect(throws: CodecRejection.negativePinOrdinal(found: -1)) {
        try RevisionStateBlobCodec.decodePinOrdinal(-1)
    }
}

/// §16/§7.4: every decode rejection maps to
/// `.persistence(.corruptStoredValue)` at the storage boundary.
@Test func rejectionsMapToCorruptStoredValue() {
    #expect(
        CodecRejection.duplicateRevisionID(Self.revisionUUID1).historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.activeRevisionIDNamesNoStoredRevision(Self.foreignUUID)
            .historyFailure == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.nonEmptyRevisionListWithNilActiveID.historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.nonCanonicalRevisionType(Self.tiffType).historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.invalidContentVersion(found: 0).historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.zeroCopyCount.historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.lastCopiedAtPrecedesFirstCopiedAt.historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.nonFiniteRevisionCreatedAt(Self.revisionUUID1)
            .historyFailure == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.nonFiniteFirstCopiedAt.historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.nonFiniteLastCopiedAt.historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.sourceObservationExceedsBound(found: 17, bound: 16)
            .historyFailure == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.negativePinOrdinal(found: -1).historyFailure
            == .persistence(.corruptStoredValue)
    )
    #expect(
        CodecRejection.unknownBlobVersion(found: 2).historyFailure
            == .persistence(.corruptStoredValue)
    )
}
}
