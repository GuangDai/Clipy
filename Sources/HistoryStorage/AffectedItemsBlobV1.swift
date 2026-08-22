/// Manual X-HCR affected-item wire codec.
/// Owning spec: `V2-03` §0.2/§4.4–§4.5; roadmap DC-25/J.2.
import Foundation
import HistoryCore

internal struct JournalLimits: Sendable {
    internal let maxAffectedItemsPerRecord: Int
    internal let maxJournalRecordCount: Int
    internal let maxJournalAgeSeconds: TimeInterval
    internal let maxJournalBytes: UInt64
    internal let compactionCadenceCommits: Int

    internal init?(
        maxAffectedItemsPerRecord: Int,
        maxJournalRecordCount: Int = 10_000,
        maxJournalAgeSeconds: TimeInterval = 604_800,
        maxJournalBytes: UInt64 = 80 * 1_048_576,
        compactionCadenceCommits: Int = 50
    ) {
        guard (1...Int(UInt16.max)).contains(maxAffectedItemsPerRecord),
              maxJournalRecordCount >= 1,
              maxJournalAgeSeconds.isFinite,
              maxJournalAgeSeconds > 0,
              maxJournalBytes >= 1,
              compactionCadenceCommits >= 1 else {
            return nil
        }
        self.maxAffectedItemsPerRecord = maxAffectedItemsPerRecord
        self.maxJournalRecordCount = maxJournalRecordCount
        self.maxJournalAgeSeconds = maxJournalAgeSeconds
        self.maxJournalBytes = maxJournalBytes
        self.compactionCadenceCommits = compactionCadenceCommits
    }

    internal static let standard: JournalLimits = {
        let retained = HistoryLimits.standard.hardMaximumRetainedItems
        let (maximum, overflow) = retained.addingReportingOverflow(1)
        precondition(!overflow)
        return JournalLimits(maxAffectedItemsPerRecord: maximum)!
    }()
}

internal struct AffectedItemsBlobV1: Sendable, Equatable {
    internal let formatVersion: UInt16
    internal let itemIDs: [UUID]
}

internal enum AffectedItemsBlobRejection: Error, Sendable, Equatable {
    case malformedBlob
    case unknownFormatVersion(found: UInt16)
    case blobExceedsDecodeEnvelope(found: Int, bound: Int)
    case countExceedsBound(found: Int, bound: Int)
    case invalidLength(found: Int, expected: Int)
    case nonAscendingOrDuplicateItemIDs
    case emptyList(changeKind: HistoryChangeKindRawV1)

    internal var historyFailure: HistoryFailure {
        switch self {
        case .emptyList:
            .persistence(.invariantViolation)
        case .malformedBlob,
             .unknownFormatVersion,
             .blobExceedsDecodeEnvelope,
             .countExceedsBound,
             .invalidLength,
             .nonAscendingOrDuplicateItemIDs:
            .persistence(.corruptStoredValue)
        }
    }
}

internal enum AffectedItemsBlobCodec {
    private static let formatVersion: UInt16 = 1
    private static let headerBytes = 4
    private static let uuidBytes = 16

    /// Normalizes payload-derived IDs into the frozen raw-byte order, then
    /// writes version/count as network-order UInt16 values followed by UUIDs.
    /// Duplicates are collapsed before the 5,001-ID admission check; no valid
    /// affected ID is truncated.
    internal static func encode(
        _ itemIDs: [HistoryItemID],
        for changeKind: HistoryChangeKindRawV1,
        limits: JournalLimits = .standard
    ) throws -> Data {
        let normalized = normalize(itemIDs)
        try validateCount(normalized.count, limits: limits)
        try validateEmptiness(normalized, for: changeKind)

        var data = Data()
        data.reserveCapacity(encodedLength(for: normalized.count))
        appendNetworkUInt16(formatVersion, to: &data)
        appendNetworkUInt16(UInt16(normalized.count), to: &data)
        for itemID in normalized {
            data.append(contentsOf: rawBytes(of: itemID.rawValue))
        }
        return data
    }

    /// Validates the fixed envelope and count before reserving output, then
    /// requires exact length and strictly ascending unique raw UUID bytes.
    internal static func decode(
        _ data: Data,
        for changeKind: HistoryChangeKindRawV1,
        limits: JournalLimits = .standard
    ) throws -> [HistoryItemID] {
        let envelope = maximumBlobBytes(limits: limits)
        guard data.count <= envelope else {
            throw AffectedItemsBlobRejection.blobExceedsDecodeEnvelope(
                found: data.count,
                bound: envelope
            )
        }
        guard data.count >= headerBytes else {
            throw AffectedItemsBlobRejection.malformedBlob
        }

        let version = readNetworkUInt16(data, at: 0)
        guard version == formatVersion else {
            throw AffectedItemsBlobRejection.unknownFormatVersion(found: version)
        }
        let count = Int(readNetworkUInt16(data, at: 2))
        try validateCount(count, limits: limits)
        let expectedLength = encodedLength(for: count)
        guard data.count == expectedLength else {
            throw AffectedItemsBlobRejection.invalidLength(
                found: data.count,
                expected: expectedLength
            )
        }

        var itemIDs: [HistoryItemID] = []
        itemIDs.reserveCapacity(count)
        var previousBytes: [UInt8]?
        for index in 0..<count {
            let start = headerBytes + index * uuidBytes
            let bytes = Array(data[start..<(start + uuidBytes)])
            if let previousBytes,
               !previousBytes.lexicographicallyPrecedes(bytes) {
                throw AffectedItemsBlobRejection
                    .nonAscendingOrDuplicateItemIDs
            }
            itemIDs.append(HistoryItemID(rawValue: uuid(from: bytes)))
            previousBytes = bytes
        }
        try validateEmptiness(itemIDs, for: changeKind)
        return itemIDs
    }

    internal static func maximumBlobBytes(
        limits: JournalLimits = .standard
    ) -> Int {
        encodedLength(for: limits.maxAffectedItemsPerRecord)
    }

    private static func normalize(
        _ itemIDs: [HistoryItemID]
    ) -> [HistoryItemID] {
        let sorted = itemIDs.sorted {
            rawBytes(of: $0.rawValue).lexicographicallyPrecedes(
                rawBytes(of: $1.rawValue)
            )
        }
        var normalized: [HistoryItemID] = []
        normalized.reserveCapacity(sorted.count)
        for itemID in sorted where normalized.last != itemID {
            normalized.append(itemID)
        }
        return normalized
    }

    private static func validateCount(
        _ count: Int,
        limits: JournalLimits
    ) throws {
        guard count <= limits.maxAffectedItemsPerRecord else {
            throw AffectedItemsBlobRejection.countExceedsBound(
                found: count,
                bound: limits.maxAffectedItemsPerRecord
            )
        }
    }

    private static func validateEmptiness(
        _ itemIDs: [HistoryItemID],
        for changeKind: HistoryChangeKindRawV1
    ) throws {
        guard itemIDs.isEmpty else { return }
        switch changeKind {
        case .clearAll, .clearUnpinned, .policySet:
            return
        case .insert, .coalesce, .pin, .unpin, .remove, .revise, .retire,
             .retireRevision:
            throw AffectedItemsBlobRejection.emptyList(changeKind: changeKind)
        }
    }

    private static func encodedLength(for count: Int) -> Int {
        CodecValidation.clampedEnvelopeSum([
            headerBytes,
            CodecValidation.clampedEnvelopeProduct(count, uuidBytes),
        ])
    }

    private static func appendNetworkUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func readNetworkUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func rawBytes(of uuid: UUID) -> [UInt8] {
        let value = uuid.uuid
        return [
            value.0, value.1, value.2, value.3,
            value.4, value.5, value.6, value.7,
            value.8, value.9, value.10, value.11,
            value.12, value.13, value.14, value.15,
        ]
    }

    private static func uuid(from bytes: [UInt8]) -> UUID {
        UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
