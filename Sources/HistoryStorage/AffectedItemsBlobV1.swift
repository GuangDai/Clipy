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

internal enum AffectedItemsBlobRejection: Error, Sendable, Equatable {
    case malformedBlob
    case unknownFormatVersion(found: UInt16)
    case unknownScope(found: UInt8)
    case invalidScope
    case invalidScopeValue
    case blobExceedsDecodeEnvelope(found: Int, bound: Int)
    case countExceedsBound(found: Int, bound: Int)
    case invalidLength(found: Int, expected: Int)
    case nonAscendingOrDuplicateItemIDs
    case emptyList(changeKind: HistoryChangeKindRawV1)

    internal var historyFailure: HistoryFailure {
        switch self {
        case .emptyList:
            .persistence(.invariantViolation)
        case .malformedBlob, .unknownFormatVersion, .unknownScope,
             .invalidScope, .invalidScopeValue, .blobExceedsDecodeEnvelope,
             .countExceedsBound, .invalidLength, .nonAscendingOrDuplicateItemIDs:
            .persistence(.corruptStoredValue)
        }
    }
}

/// One current tagged format, with no historical decoding path. Explicit
/// membership is bounded independently of constant-size bulk scope counts.
internal enum AffectedItemsBlobCodec {
    private static let formatVersion: UInt16 = 2

    internal static func encode(
        _ affectedItems: HistoryAffectedItems,
        for changeKind: HistoryChangeKindRawV1,
        limits: JournalLimits = .standard
    ) throws -> Data {
        let scope: HistoryAffectedItems
        if case .explicit(let ids) = affectedItems {
            var unique: [HistoryItemID] = []
            for id in ids.sorted() where unique.last != id { unique.append(id) }
            scope = .explicit(unique)
        } else {
            scope = affectedItems
        }
        try validate(scope, for: changeKind, limits: limits)
        var data = Data([0, UInt8(formatVersion)])
        switch scope {
        case .explicit(let ids):
            data.append(1)
            data.append(UInt8(truncatingIfNeeded: ids.count >> 8))
            data.append(UInt8(truncatingIfNeeded: ids.count))
            for id in ids { append(id, to: &data) }
        case .all(let count):
            data.append(2)
            append(UInt64(count), to: &data)
        case .unpinned(let count):
            data.append(3)
            append(UInt64(count), to: &data)
        case .unpinnedPrefix(let through, let excluded, let count, let primary):
            data.append(4)
            append(UInt64(count), to: &data)
            append(through.lastCopiedAt.timeIntervalSinceReferenceDate.bitPattern, to: &data)
            append(through.itemID, to: &data)
            appendOptional(excluded, to: &data)
            appendOptional(primary, to: &data)
        case .retention(let retired, let pruned):
            data.append(5)
            append(UInt64(retired), to: &data)
            append(UInt64(pruned), to: &data)
        }
        return data
    }

    internal static func decode(
        _ data: Data,
        for changeKind: HistoryChangeKindRawV1,
        limits: JournalLimits = .standard
    ) throws -> HistoryAffectedItems {
        let bound = maximumBlobBytes(limits: limits)
        guard data.count <= bound else {
            throw AffectedItemsBlobRejection.blobExceedsDecodeEnvelope(found: data.count, bound: bound)
        }
        var reader = ScopeReader(bytes: Array(data))
        let version = UInt16(try reader.byte()) << 8 | UInt16(try reader.byte())
        guard version == formatVersion else {
            throw AffectedItemsBlobRejection.unknownFormatVersion(found: version)
        }
        let scope: HistoryAffectedItems
        switch try reader.byte() {
        case 1:
            let count = Int(try reader.byte()) << 8 | Int(try reader.byte())
            guard count <= limits.maxAffectedItemsPerRecord else {
                throw AffectedItemsBlobRejection.countExceedsBound(
                    found: count, bound: limits.maxAffectedItemsPerRecord)
            }
            let expected = 5 + 16 * count
            guard data.count == expected else {
                throw AffectedItemsBlobRejection.invalidLength(found: data.count, expected: expected)
            }
            var ids: [HistoryItemID] = []
            ids.reserveCapacity(count)
            for _ in 0..<count {
                let id = try reader.itemID()
                if let last = ids.last, !(last < id) {
                    throw AffectedItemsBlobRejection.nonAscendingOrDuplicateItemIDs
                }
                ids.append(id)
            }
            scope = .explicit(ids)
        case 2:
            scope = .all(retiredItems: try reader.count())
        case 3:
            scope = .unpinned(retiredItems: try reader.count())
        case 4:
            let count = try reader.count()
            let date = Date(timeIntervalSinceReferenceDate: Double(bitPattern: try reader.uint64()))
            let boundary = try reader.itemID()
            let excluded = try reader.optionalItemID()
            let primary = try reader.optionalItemID()
            scope = .unpinnedPrefix(through: .init(lastCopiedAt: date, itemID: boundary),
                excluding: excluded, retiredItems: count, primaryItemID: primary)
        case 5:
            scope = .retention(retiredItems: try reader.count(), prunedRevisions: try reader.count())
        case let tag:
            throw AffectedItemsBlobRejection.unknownScope(found: tag)
        }
        guard reader.offset == data.count else {
            throw AffectedItemsBlobRejection.invalidLength(found: data.count, expected: reader.offset)
        }
        try validate(scope, for: changeKind, limits: limits)
        return scope
    }

    internal static func maximumBlobBytes(limits: JournalLimits = .standard) -> Int {
        max(5 + 16 * limits.maxAffectedItemsPerRecord, 69)
    }

    internal static func validate(
        _ scope: HistoryAffectedItems,
        for kind: HistoryChangeKindRawV1,
        limits: JournalLimits
    ) throws {
        switch scope {
        case .explicit(let ids):
            guard ids.count <= limits.maxAffectedItemsPerRecord else {
                throw AffectedItemsBlobRejection.countExceedsBound(
                    found: ids.count, bound: limits.maxAffectedItemsPerRecord)
            }
            guard kind != .clearAll, kind != .clearUnpinned else {
                throw AffectedItemsBlobRejection.invalidScope
            }
            if kind == .policySet {
                guard ids.isEmpty else { throw AffectedItemsBlobRejection.invalidScope }
            } else if ids.isEmpty {
                throw AffectedItemsBlobRejection.emptyList(changeKind: kind)
            }
        case .all(let count):
            guard kind == .clearAll else { throw AffectedItemsBlobRejection.invalidScope }
            guard count > 0 else { throw AffectedItemsBlobRejection.invalidScopeValue }
        case .unpinned(let count):
            guard kind == .clearUnpinned else { throw AffectedItemsBlobRejection.invalidScope }
            guard count > 0 else { throw AffectedItemsBlobRejection.invalidScopeValue }
        case .unpinnedPrefix(let through, let excluded, let count, let primary):
            guard count > 0, through.lastCopiedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw AffectedItemsBlobRejection.invalidScopeValue
            }
            guard through.itemID != excluded else { throw AffectedItemsBlobRejection.invalidScope }
            switch kind {
            case .insert, .coalesce, .revise:
                guard primary != nil, excluded == primary else {
                    throw AffectedItemsBlobRejection.invalidScope
                }
            case .retire:
                guard primary == nil else { throw AffectedItemsBlobRejection.invalidScope }
            default:
                throw AffectedItemsBlobRejection.invalidScope
            }
        case .retention(let retired, let pruned):
            guard retired >= 0, pruned >= 0 else { throw AffectedItemsBlobRejection.invalidScopeValue }
            let expected: HistoryChangeKindRawV1 = retired > 0 ? .retire
                : pruned > 0 ? .retireRevision : .policySet
            guard kind == expected else { throw AffectedItemsBlobRejection.invalidScope }
        }
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    private static func append(_ id: HistoryItemID, to data: inout Data) {
        let u = id.rawValue.uuid
        data.append(contentsOf: [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                                 u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
    }

    private static func appendOptional(_ id: HistoryItemID?, to data: inout Data) {
        data.append(id == nil ? 0 : 1)
        if let id { append(id, to: &data) }
    }

    /// Local cursor for this fixed scope grammar; checks before every read.
    private struct ScopeReader {
        let bytes: [UInt8]
        var offset = 0

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw AffectedItemsBlobRejection.malformedBlob }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func uint64() throws -> UInt64 {
            var value: UInt64 = 0
            for _ in 0..<8 { value = (value << 8) | UInt64(try byte()) }
            return value
        }

        mutating func count() throws -> Int {
            guard let count = Int(exactly: try uint64()) else {
                throw AffectedItemsBlobRejection.invalidScopeValue
            }
            return count
        }

        mutating func itemID() throws -> HistoryItemID {
            guard bytes.count - offset >= 16 else { throw AffectedItemsBlobRejection.malformedBlob }
            let b = Array(bytes[offset..<(offset + 16)])
            offset += 16
            return HistoryItemID(rawValue: UUID(uuid: (
                b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])))
        }

        mutating func optionalItemID() throws -> HistoryItemID? {
            switch try byte() {
            case 0: nil
            case 1: try itemID()
            default: throw AffectedItemsBlobRejection.invalidScopeValue
            }
        }
    }
}
