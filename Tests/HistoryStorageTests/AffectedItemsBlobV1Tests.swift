/// Current HCR scope codec proofs (V2-03 §4.4–§4.5).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

@Suite("Affected item scope codec")
struct AffectedItemsBlobV1Tests {
    private static let first = itemID(1)
    private static let second = itemID(2)
    private static let third = itemID(3)
    private static let cutoff = RetentionEvictionKey(
        lastCopiedAt: Date(timeIntervalSinceReferenceDate: 1),
        itemID: second
    )
    private static let kinds: [HistoryChangeKindRawV1] = [
        .insert, .coalesce, .pin, .unpin, .remove, .clearAll,
        .clearUnpinned, .revise, .retire, .policySet, .retireRevision
    ]

    @Test("explicit scope wire is network order, sorted, unique, and deterministic")
    func exactManualWire() throws {
        let source = HistoryAffectedItems.explicit([Self.second, Self.first, Self.second])
        let blob = try AffectedItemsBlobCodec.encode(source, for: .insert)
        var expected = Data([0, 2, 1, 0, 2])
        expected.append(Self.uuidBytes(Self.first))
        expected.append(Self.uuidBytes(Self.second))
        #expect(blob == expected)
        #expect(blob.count == 5 + 2 * 16)
        #expect(try AffectedItemsBlobCodec.decode(blob, for: .insert) == .explicit([Self.first, Self.second]))
        #expect(try AffectedItemsBlobCodec.encode(source, for: .insert) == blob)
    }

    @Test("only policySet admits an empty explicit scope and it cannot claim item changes")
    func emptyListKindMatrix() throws {
        let blob = try AffectedItemsBlobCodec.encode(.explicit([]), for: .policySet)
        #expect(blob == Data([0, 2, 1, 0, 0]))
        #expect(try AffectedItemsBlobCodec.decode(blob, for: .policySet) == .explicit([]))
        for kind in Self.kinds where kind != .policySet {
            #expect(throws: AffectedItemsBlobRejection.self) {
                try AffectedItemsBlobCodec.encode(.explicit([]), for: kind)
            }
            #expect(throws: AffectedItemsBlobRejection.self) {
                try AffectedItemsBlobCodec.decode(blob, for: kind)
            }
        }
        #expect(throws: AffectedItemsBlobRejection.invalidScope) {
            try AffectedItemsBlobCodec.encode(.explicit([Self.first]), for: .policySet)
        }
    }

    @Test("nonempty explicit scopes cover bounded mutations but never bulk clear")
    func explicitKindMatrix() throws {
        let scope = HistoryAffectedItems.explicit([Self.first])
        let wire = try AffectedItemsBlobCodec.encode(scope, for: .remove)
        for kind in Self.kinds {
            if [.clearAll, .clearUnpinned, .policySet].contains(kind) {
                #expect(throws: AffectedItemsBlobRejection.invalidScope) {
                    try AffectedItemsBlobCodec.encode(scope, for: kind)
                }
                #expect(throws: AffectedItemsBlobRejection.invalidScope) {
                    try AffectedItemsBlobCodec.decode(wire, for: kind)
                }
            } else {
                #expect(try AffectedItemsBlobCodec.decode(wire, for: kind) == scope)
            }
        }
    }

    @Test("bulk clear stores actual network-order counts without enumerating IDs")
    func clearScopesHaveExactConstantWire() throws {
        let all = try AffectedItemsBlobCodec.encode(.all(retiredItems: 1_000_000), for: .clearAll)
        let unpinned = try AffectedItemsBlobCodec.encode(.unpinned(retiredItems: 1_000_000), for: .clearUnpinned)
        #expect(all == Data([0, 2, 2, 0, 0, 0, 0, 0, 15, 66, 64]))
        #expect(unpinned == Data([0, 2, 3, 0, 0, 0, 0, 0, 15, 66, 64]))
        #expect(try AffectedItemsBlobCodec.decode(all, for: .clearAll) == .all(retiredItems: 1_000_000))
        #expect(try AffectedItemsBlobCodec.decode(unpinned, for: .clearUnpinned) == .unpinned(retiredItems: 1_000_000))
        for count in [1, 1_000_000, Int.max] {
            for (scope, kind) in [
                (HistoryAffectedItems.all(retiredItems: count), HistoryChangeKindRawV1.clearAll),
                (.unpinned(retiredItems: count), .clearUnpinned)
            ] {
                let blob = try AffectedItemsBlobCodec.encode(scope, for: kind)
                #expect(blob.count == 11)
                #expect(try AffectedItemsBlobCodec.decode(blob, for: kind) == scope)
            }
        }
    }

    @Test("clear scopes reject unrelated kinds and nonpositive retirement counts")
    func clearScopeKindAndCountMatrix() throws {
        for (scope, permitted) in [
            (HistoryAffectedItems.all(retiredItems: 1), HistoryChangeKindRawV1.clearAll),
            (.unpinned(retiredItems: 1), .clearUnpinned)
        ] {
            let wire = try AffectedItemsBlobCodec.encode(scope, for: permitted)
            for kind in Self.kinds where kind != permitted {
                #expect(throws: AffectedItemsBlobRejection.invalidScope) {
                    try AffectedItemsBlobCodec.encode(scope, for: kind)
                }
                #expect(throws: AffectedItemsBlobRejection.invalidScope) {
                    try AffectedItemsBlobCodec.decode(wire, for: kind)
                }
            }
        }
        for count in [0, -1] {
            #expect(throws: AffectedItemsBlobRejection.self) {
                try AffectedItemsBlobCodec.encode(.all(retiredItems: count), for: .clearAll)
            }
            #expect(throws: AffectedItemsBlobRejection.self) {
                try AffectedItemsBlobCodec.encode(.unpinned(retiredItems: count), for: .clearUnpinned)
            }
        }
        for (tag, kind) in [(UInt8(2), HistoryChangeKindRawV1.clearAll), (3, .clearUnpinned)] {
            var empty = Data([0, 2, tag])
            empty.append(Self.uint64Bytes(0))
            #expect(throws: AffectedItemsBlobRejection.self) {
                try AffectedItemsBlobCodec.decode(empty, for: kind)
            }
        }
    }

    @Test("prefix wire retains count, exact cutoff, exclusion, and primary")
    func prefixHasExactConstantWire() throws {
        let scope = HistoryAffectedItems.unpinnedPrefix(
            through: Self.cutoff, excluding: Self.first,
            retiredItems: 1_000_000, primaryItemID: Self.first
        )
        let blob = try AffectedItemsBlobCodec.encode(scope, for: .insert)
        var expected = Data([0, 2, 4, 0, 0, 0, 0, 0, 15, 66, 64])
        expected.append(contentsOf: [0x3f, 0xf0, 0, 0, 0, 0, 0, 0]) // Double(1).bitPattern
        expected.append(Self.uuidBytes(Self.second))
        expected.append(1)
        expected.append(Self.uuidBytes(Self.first))
        expected.append(1)
        expected.append(Self.uuidBytes(Self.first))
        #expect(blob == expected)
        #expect(blob.count == 69)
        #expect(try AffectedItemsBlobCodec.decode(blob, for: .insert) == scope)
        let smallExplicitLimit = JournalLimits(maxAffectedItemsPerRecord: 1)!
        #expect(try AffectedItemsBlobCodec.decode(blob, for: .insert, limits: smallExplicitLimit) == scope)
        let large = try AffectedItemsBlobCodec.encode(.unpinnedPrefix(
            through: Self.cutoff, excluding: Self.first,
            retiredItems: Int.max, primaryItemID: Self.first
        ), for: .insert)
        #expect(large.count == blob.count)
        #expect(try AffectedItemsBlobCodec.decode(large, for: .insert) == .unpinnedPrefix(
            through: Self.cutoff, excluding: Self.first,
            retiredItems: Int.max, primaryItemID: Self.first
        ))
    }

    @Test("prefix mutation kinds require the protected primary while retire carries no primary")
    func prefixKindMatrix() throws {
        for kind in [HistoryChangeKindRawV1.insert, .coalesce, .revise] {
            let scope = HistoryAffectedItems.unpinnedPrefix(
                through: Self.cutoff, excluding: Self.first, retiredItems: 2, primaryItemID: Self.first
            )
            let wire = try AffectedItemsBlobCodec.encode(scope, for: kind)
            #expect(try AffectedItemsBlobCodec.decode(wire, for: kind) == scope)
            for (excluded, primary) in [
                (Optional<HistoryItemID>.none, Optional<HistoryItemID>.none),
                (Self.first, nil), (nil, Self.first), (Self.third, Self.first)
            ] {
                #expect(throws: AffectedItemsBlobRejection.invalidScope) {
                    try AffectedItemsBlobCodec.encode(.unpinnedPrefix(
                        through: Self.cutoff, excluding: excluded, retiredItems: 2, primaryItemID: primary
                    ), for: kind)
                }
            }
        }
        for excluded in [Optional<HistoryItemID>.none, Self.first] {
            let scope = HistoryAffectedItems.unpinnedPrefix(
                through: Self.cutoff, excluding: excluded, retiredItems: 2, primaryItemID: nil
            )
            let wire = try AffectedItemsBlobCodec.encode(scope, for: .retire)
            #expect(wire.count == (excluded == nil ? 37 : 53))
            #expect(try AffectedItemsBlobCodec.decode(wire, for: .retire) == scope)
        }
        let withPrimary = HistoryAffectedItems.unpinnedPrefix(
            through: Self.cutoff, excluding: Self.first, retiredItems: 2, primaryItemID: Self.first
        )
        let wire = try AffectedItemsBlobCodec.encode(withPrimary, for: .insert)
        for kind in Self.kinds where ![.insert, .coalesce, .revise].contains(kind) {
            #expect(throws: AffectedItemsBlobRejection.invalidScope) {
                try AffectedItemsBlobCodec.encode(withPrimary, for: kind)
            }
            #expect(throws: AffectedItemsBlobRejection.invalidScope) {
                try AffectedItemsBlobCodec.decode(wire, for: kind)
            }
        }
    }

    @Test("prefix rejects excluded cutoffs, nonpositive counts, and nonfinite dates")
    func prefixSemanticValueRejections() throws {
        #expect(throws: AffectedItemsBlobRejection.self) {
            try AffectedItemsBlobCodec.encode(.unpinnedPrefix(
                through: Self.cutoff, excluding: Self.second, retiredItems: 1, primaryItemID: nil
            ), for: .retire)
        }
        for count in [0, -1] {
            #expect(throws: AffectedItemsBlobRejection.self) {
                try AffectedItemsBlobCodec.encode(.unpinnedPrefix(
                    through: Self.cutoff, excluding: nil, retiredItems: count, primaryItemID: nil
                ), for: .retire)
            }
        }
        var emptyPrefix = try AffectedItemsBlobCodec.encode(.unpinnedPrefix(
            through: Self.cutoff, excluding: nil, retiredItems: 1, primaryItemID: nil
        ), for: .retire)
        emptyPrefix.replaceSubrange(3..<11, with: Self.uint64Bytes(0))
        #expect(throws: AffectedItemsBlobRejection.self) {
            try AffectedItemsBlobCodec.decode(emptyPrefix, for: .retire)
        }
        for interval in [Double.nan, .infinity, -.infinity] {
            #expect(throws: AffectedItemsBlobRejection.invalidScopeValue) {
                try AffectedItemsBlobCodec.encode(.unpinnedPrefix(
                    through: RetentionEvictionKey(
                        lastCopiedAt: Date(timeIntervalSinceReferenceDate: interval), itemID: Self.second
                    ), excluding: nil, retiredItems: 1, primaryItemID: nil
                ), for: .retire)
            }
            var wire = try AffectedItemsBlobCodec.encode(.unpinnedPrefix(
                through: Self.cutoff, excluding: nil, retiredItems: 1, primaryItemID: nil
            ), for: .retire)
            wire.replaceSubrange(11..<19, with: Self.uint64Bytes(interval.bitPattern))
            #expect(throws: AffectedItemsBlobRejection.invalidScopeValue) {
                try AffectedItemsBlobCodec.decode(wire, for: .retire)
            }
        }
    }

    @Test("retention aggregate uses actual totals and the matching change kind")
    func retentionScopeRoundTripAndKindMatrix() throws {
        for (retired, pruned, permitted) in [
            (1_000_000, 2_000_000, HistoryChangeKindRawV1.retire),
            (1_000_000, 0, .retire),
            (0, 2_000_000, .retireRevision),
            (0, 0, .policySet),
            (Int.max, Int.max, .retire)
        ] {
            let scope = HistoryAffectedItems.retention(retiredItems: retired, prunedRevisions: pruned)
            let wire = try AffectedItemsBlobCodec.encode(scope, for: permitted)
            #expect(wire.count == 19)
            #expect(Array(wire.prefix(3)) == [0, 2, 5])
            #expect(Data(wire[3..<11]) == Self.uint64Bytes(UInt64(retired)))
            #expect(Data(wire[11..<19]) == Self.uint64Bytes(UInt64(pruned)))
            #expect(try AffectedItemsBlobCodec.decode(wire, for: permitted) == scope)
            for kind in Self.kinds where kind != permitted {
                #expect(throws: AffectedItemsBlobRejection.invalidScope) {
                    try AffectedItemsBlobCodec.encode(scope, for: kind)
                }
                #expect(throws: AffectedItemsBlobRejection.invalidScope) {
                    try AffectedItemsBlobCodec.decode(wire, for: kind)
                }
            }
        }
        for (retired, pruned) in [(-1, 0), (0, -1), (1, -1), (-1, 1)] {
            #expect(throws: AffectedItemsBlobRejection.invalidScopeValue) {
                try AffectedItemsBlobCodec.encode(
                    .retention(retiredItems: retired, prunedRevisions: pruned), for: .retire
                )
            }
        }
    }

    @Test("retired and pruned network counters cannot overflow Int")
    func unsignedCountOverflowFailsClosed() throws {
        for (scope, kind) in Self.validScopes {
            if case .explicit = scope { continue }
            var wire = try AffectedItemsBlobCodec.encode(scope, for: kind)
            wire.replaceSubrange(3..<11, with: Self.uint64Bytes(UInt64.max))
            #expect(throws: AffectedItemsBlobRejection.invalidScopeValue) {
                try AffectedItemsBlobCodec.decode(wire, for: kind)
            }
        }
        var retention = try AffectedItemsBlobCodec.encode(
            .retention(retiredItems: 1, prunedRevisions: 1), for: .retire
        )
        retention.replaceSubrange(11..<19, with: Self.uint64Bytes(UInt64.max))
        #expect(throws: AffectedItemsBlobRejection.invalidScopeValue) {
            try AffectedItemsBlobCodec.decode(retention, for: .retire)
        }
    }

    @Test("only the current version and known scope tags are accepted")
    func versionAndScopeRejections() {
        for prefix in [Data(), Data([0]), Data([0, 2])] {
            #expect(throws: AffectedItemsBlobRejection.malformedBlob) {
                try AffectedItemsBlobCodec.decode(prefix, for: .policySet)
            }
        }
        for version in [UInt16(0), 1, 3, .max] {
            let data = Data([UInt8(version >> 8), UInt8(truncatingIfNeeded: version), 1, 0, 0])
            #expect(throws: AffectedItemsBlobRejection.unknownFormatVersion(found: version)) {
                try AffectedItemsBlobCodec.decode(data, for: .policySet)
            }
        }
        for tag in [UInt8(0), 6, .max] {
            #expect(throws: AffectedItemsBlobRejection.unknownScope(found: tag)) {
                try AffectedItemsBlobCodec.decode(Data([0, 2, tag]), for: .policySet)
            }
        }
    }

    @Test("every scope rejects each truncation and trailing bytes")
    func exactLengthIsRequiredForEveryScope() throws {
        for (scope, kind) in Self.validScopes {
            let wire = try AffectedItemsBlobCodec.encode(scope, for: kind)
            for length in 0..<wire.count {
                #expect(throws: AffectedItemsBlobRejection.self) {
                    try AffectedItemsBlobCodec.decode(Data(wire.prefix(length)), for: kind)
                }
            }
            var trailing = wire
            trailing.append(0)
            #expect(throws: AffectedItemsBlobRejection.self) {
                try AffectedItemsBlobCodec.decode(trailing, for: kind)
            }
        }
    }

    @Test("prefix option flags accept only zero or one and preserve identity semantics")
    func prefixWireFlagsAndIdentityRejections() throws {
        let source = try AffectedItemsBlobCodec.encode(.unpinnedPrefix(
            through: Self.cutoff, excluding: Self.first, retiredItems: 1, primaryItemID: Self.first
        ), for: .insert)
        for offset in [35, 52] {
            for flag in [UInt8(2), .max] {
                var invalid = source
                invalid[offset] = flag
                #expect(throws: AffectedItemsBlobRejection.self) {
                    try AffectedItemsBlobCodec.decode(invalid, for: .insert)
                }
            }
        }
        var excludedCutoff = source
        excludedCutoff.replaceSubrange(19..<35, with: Self.uuidBytes(Self.first))
        #expect(throws: AffectedItemsBlobRejection.self) {
            try AffectedItemsBlobCodec.decode(excludedCutoff, for: .insert)
        }
        var differentPrimary = source
        differentPrimary.replaceSubrange(53..<69, with: Self.uuidBytes(Self.third))
        #expect(throws: AffectedItemsBlobRejection.invalidScope) {
            try AffectedItemsBlobCodec.decode(differentPrimary, for: .insert)
        }
    }

    @Test("decoder rejects duplicate and descending raw UUID order")
    func normalizedOrderRejections() throws {
        let sorted = try AffectedItemsBlobCodec.encode(.explicit([Self.first, Self.second]), for: .insert)
        var duplicate = sorted
        duplicate.replaceSubrange(21..<37, with: sorted[5..<21])
        #expect(throws: AffectedItemsBlobRejection.nonAscendingOrDuplicateItemIDs) {
            try AffectedItemsBlobCodec.decode(duplicate, for: .insert)
        }
        var descending = Data(sorted.prefix(5))
        descending.append(contentsOf: sorted[21..<37])
        descending.append(contentsOf: sorted[5..<21])
        #expect(throws: AffectedItemsBlobRejection.nonAscendingOrDuplicateItemIDs) {
            try AffectedItemsBlobCodec.decode(descending, for: .insert)
        }
    }

    @Test("explicit IDs retain the 5001 bound while aggregate scopes stay constant")
    func explicitCountBoundary() throws {
        #expect(JournalLimits.standard.maxAffectedItemsPerRecord == 5_001)
        let maximum = (0..<5_001).map(Self.itemID)
        let blob = try AffectedItemsBlobCodec.encode(.explicit(maximum), for: .retire)
        #expect(blob.count == 5 + 5_001 * 16)
        #expect(try AffectedItemsBlobCodec.decode(blob, for: .retire) == .explicit(maximum))
        let overBound = (0..<5_002).map(Self.itemID)
        #expect(throws: AffectedItemsBlobRejection.countExceedsBound(found: 5_002, bound: 5_001)) {
            try AffectedItemsBlobCodec.encode(.explicit(overBound), for: .retire)
        }
        let limits = JournalLimits(maxAffectedItemsPerRecord: 1)!
        let aggregate = try AffectedItemsBlobCodec.encode(.all(retiredItems: 1_000_000), for: .clearAll, limits: limits)
        #expect(try AffectedItemsBlobCodec.decode(aggregate, for: .clearAll, limits: limits) == .all(retiredItems: 1_000_000))
    }

    @Test("count bounds precede output allocation and envelope includes all scopes")
    func decodeBounds() throws {
        let limits = JournalLimits(maxAffectedItemsPerRecord: 1)!
        var countAboveBound = Data([0, 2, 1, 0, 2])
        countAboveBound.append(Self.uuidBytes(Self.first))
        #expect(throws: AffectedItemsBlobRejection.countExceedsBound(found: 2, bound: 1)) {
            try AffectedItemsBlobCodec.decode(countAboveBound, for: .insert, limits: limits)
        }
        #expect(AffectedItemsBlobCodec.maximumBlobBytes(limits: limits) == 69)
        #expect(AffectedItemsBlobCodec.maximumBlobBytes() == 5 + 5_001 * 16)
        #expect(throws: AffectedItemsBlobRejection.blobExceedsDecodeEnvelope(found: 70, bound: 69)) {
            try AffectedItemsBlobCodec.decode(Data(repeating: 0, count: 70), for: .insert, limits: limits)
        }
    }

    @Test("scope shape rejections map to corrupt stored values")
    func rejectionMapping() {
        for rejection in [
            AffectedItemsBlobRejection.malformedBlob, .invalidScope,
            .invalidScopeValue, .unknownScope(found: 6)
        ] {
            #expect(rejection.historyFailure == .persistence(.corruptStoredValue))
        }
        #expect(AffectedItemsBlobRejection.emptyList(changeKind: .insert).historyFailure == .persistence(.invariantViolation))
    }

    private static var validScopes: [(HistoryAffectedItems, HistoryChangeKindRawV1)] {
        [
            (.explicit([first, second]), .insert),
            (.explicit([]), .policySet),
            (.all(retiredItems: 1), .clearAll),
            (.unpinned(retiredItems: 1), .clearUnpinned),
            (.unpinnedPrefix(through: cutoff, excluding: nil, retiredItems: 1, primaryItemID: nil), .retire),
            (.unpinnedPrefix(through: cutoff, excluding: first, retiredItems: 1, primaryItemID: nil), .retire),
            (.unpinnedPrefix(through: cutoff, excluding: first, retiredItems: 1, primaryItemID: first), .insert),
            (.retention(retiredItems: 1, prunedRevisions: 2), .retire)
        ]
    }

    private static func uint64Bytes(_ value: UInt64) -> Data {
        Data((0..<8).map { UInt8(truncatingIfNeeded: value >> ((7 - $0) * 8)) })
    }

    private static func uuidBytes(_ item: HistoryItemID) -> Data {
        withUnsafeBytes(of: item.rawValue.uuid) { Data($0) }
    }

    private static func itemID(_ value: Int) -> HistoryItemID {
        let raw = UInt64(value).bigEndian
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: raw) { bytes.replaceSubrange(8..<16, with: $0) }
        return HistoryItemID(rawValue: UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }
}
