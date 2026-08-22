/// DC-25 X-HCR manual affected-item codec proofs.
/// Owning spec: `V2-03` §0.2/§4.4–§4.5.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("AffectedItemsBlobV1")
struct AffectedItemsBlobV1Tests {
    private static let first = itemID(1)
    private static let second = itemID(2)

    @Test("manual network-order wire is exact, sorted, unique, and deterministic")
    func exactManualWire() throws {
        let blob = try AffectedItemsBlobCodec.encode(
            [Self.second, Self.first, Self.second],
            for: .insert
        )

        #expect(blob.count == 4 + 2 * 16)
        #expect(Array(blob.prefix(4)) == [0, 1, 0, 2])
        #expect(
            try AffectedItemsBlobCodec.decode(blob, for: .insert)
                == [Self.first, Self.second]
        )
        #expect(
            try AffectedItemsBlobCodec.encode(
                [Self.second, Self.first, Self.second],
                for: .insert
            ) == blob
        )
    }

    @Test("only self-describing kinds admit an empty affected-ID list")
    func emptyListKindMatrix() throws {
        for kind in [
            HistoryChangeKindRawV1.clearAll,
            .clearUnpinned,
            .policySet,
        ] {
            let blob = try AffectedItemsBlobCodec.encode([], for: kind)
            #expect(Array(blob) == [0, 1, 0, 0])
            #expect(try AffectedItemsBlobCodec.decode(blob, for: kind).isEmpty)
        }

        for kind in [
            HistoryChangeKindRawV1.insert,
            .coalesce,
            .pin,
            .unpin,
            .remove,
            .revise,
            .retire,
            .retireRevision,
        ] {
            #expect(
                throws: AffectedItemsBlobRejection.emptyList(changeKind: kind)
            ) {
                try AffectedItemsBlobCodec.encode([], for: kind)
            }
        }
    }

    @Test("unknown version, malformed header, and wrong length fail closed")
    func shapeRejections() {
        #expect(throws: AffectedItemsBlobRejection.malformedBlob) {
            try AffectedItemsBlobCodec.decode(Data([0, 1, 0]), for: .insert)
        }
        #expect(
            throws: AffectedItemsBlobRejection.unknownFormatVersion(found: 2)
        ) {
            try AffectedItemsBlobCodec.decode(
                Data([0, 2, 0, 0]),
                for: .policySet
            )
        }
        #expect(
            throws: AffectedItemsBlobRejection.invalidLength(
                found: 5,
                expected: 4
            )
        ) {
            try AffectedItemsBlobCodec.decode(
                Data([0, 1, 0, 0, 0]),
                for: .policySet
            )
        }
    }

    @Test("decoder rejects duplicate and non-ascending raw UUID order")
    func normalizedOrderRejections() throws {
        let sorted = try AffectedItemsBlobCodec.encode(
            [Self.first, Self.second],
            for: .insert
        )
        var duplicate = sorted
        duplicate.replaceSubrange(20..<36, with: sorted[4..<20])
        #expect(
            throws: AffectedItemsBlobRejection
                .nonAscendingOrDuplicateItemIDs
        ) {
            try AffectedItemsBlobCodec.decode(duplicate, for: .insert)
        }

        var descending = Data(sorted.prefix(4))
        descending.append(contentsOf: sorted[20..<36])
        descending.append(contentsOf: sorted[4..<20])
        #expect(
            throws: AffectedItemsBlobRejection
                .nonAscendingOrDuplicateItemIDs
        ) {
            try AffectedItemsBlobCodec.decode(descending, for: .insert)
        }
    }

    @Test("standard bound accepts 5,001 unique IDs and rejects 5,002")
    func frozenCountBoundary() throws {
        #expect(JournalLimits.standard.maxAffectedItemsPerRecord == 5_001)
        let maximum = (0..<5_001).map(Self.itemID)
        let blob = try AffectedItemsBlobCodec.encode(maximum, for: .retire)
        #expect(blob.count == 4 + 5_001 * 16)
        #expect(
            try AffectedItemsBlobCodec.decode(blob, for: .retire).count
                == 5_001
        )

        let overBound = (0..<5_002).map(Self.itemID)
        #expect(
            throws: AffectedItemsBlobRejection.countExceedsBound(
                found: 5_002,
                bound: 5_001
            )
        ) {
            try AffectedItemsBlobCodec.encode(overBound, for: .retire)
        }
    }

    @Test("count and byte bounds reject before output allocation")
    func decodeBounds() throws {
        let limits = JournalLimits(maxAffectedItemsPerRecord: 1)!
        var countAboveBound = Data([0, 1, 0, 2])
        countAboveBound.append(contentsOf: Array(repeating: 0, count: 16))
        #expect(
            throws: AffectedItemsBlobRejection.countExceedsBound(
                found: 2,
                bound: 1
            )
        ) {
            try AffectedItemsBlobCodec.decode(
                countAboveBound,
                for: .insert,
                limits: limits
            )
        }

        let envelope = AffectedItemsBlobCodec.maximumBlobBytes(limits: limits)
        #expect(envelope == 20)
        #expect(
            throws: AffectedItemsBlobRejection.blobExceedsDecodeEnvelope(
                found: 21,
                bound: 20
            )
        ) {
            try AffectedItemsBlobCodec.decode(
                Data(repeating: 0, count: 21),
                for: .insert,
                limits: limits
            )
        }
    }

    @Test("codec rejections map to the documented fail-closed boundary")
    func rejectionMapping() {
        #expect(
            AffectedItemsBlobRejection.malformedBlob.historyFailure
                == .persistence(.corruptStoredValue)
        )
        #expect(
            AffectedItemsBlobRejection.emptyList(changeKind: .insert)
                .historyFailure == .persistence(.invariantViolation)
        )
    }

    private static func itemID(_ value: Int) -> HistoryItemID {
        let raw = UInt64(value).bigEndian
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: raw) { rawBytes in
            bytes.replaceSubrange(8..<16, with: rawBytes)
        }
        return HistoryItemID(rawValue: UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }
}
