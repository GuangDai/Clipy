import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct RevisionStateBlobCodecTests {
    /// Occurrence first/last time and first/last source, pin ordinal, and
    /// Content Version survive as validated row scalars (§7.3: "occurrence
    /// first/last source, pin ordinal"; docs/storage.md).
    @Test func decodingPreservesRowScalars() throws {
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

    /// §7.4: a zero Content Version (docs/storage.md: always at
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
        let bound = HistoryLimits.standard.maximumSourceApplicationObservationUTF8Bytes
        #expect(
            throws: CodecRejection.sourceObservationExceedsBound(
                found: bound + 1,
                bound: bound
            )
        ) {
            try RevisionStateBlobCodec.decodeOccurrence(
                firstCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
                copyCount: 1,
                firstSource: String(repeating: "s", count: bound + 1),
                lastSource: nil
            )
        }
    }

    /// §7.4: a negative pin ordinal is corruption.
    @Test func decodeRejectsNegativePinOrdinal() {
        #expect(throws: CodecRejection.negativePinOrdinal(found: -1)) {
            try RevisionStateBlobCodec.decodePinOrdinal(-1)
        }
    }

    @Test func invalidRowScalarsMapToCorruptStoredValue() {
        let rejections: [CodecRejection] = [
            .invalidContentVersion(found: 0), .zeroCopyCount,
            .lastCopiedAtPrecedesFirstCopiedAt, .nonFiniteFirstCopiedAt,
            .nonFiniteLastCopiedAt, .sourceObservationExceedsBound(found: 17, bound: 16),
            .negativePinOrdinal(found: -1),
        ]
        for rejection in rejections {
            #expect(rejection.historyFailure == .persistence(.corruptStoredValue))
        }
    }
}
