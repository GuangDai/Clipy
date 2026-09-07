import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

struct OrderedRetentionSelectionTests {
    private func item(_ index: Int, copiedAt: Double? = nil, pinned: Bool = false,
                      canonicalBytes: Int = 1, revisionBytes: Int = 0) -> RetentionExpansionItemSummary {
        let id = HistoryItemID(rawValue: UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            UInt8((index >> 24) & 255), UInt8((index >> 16) & 255),
            UInt8((index >> 8) & 255), UInt8(index & 255))))
        return RetentionExpansionItemSummary(id: id,
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: copiedAt ?? Double(index)),
            pinOrdinal: pinned ? PinOrdinal(rawValue: 0) : nil,
            canonicalBytes: canonicalBytes, revisionCount: revisionBytes == 0 ? 0 : 1,
            revisionBytes: revisionBytes)
    }

    private func summary(_ item: RetentionExpansionItemSummary) -> RetainedItemSummary {
        RetainedItemSummary(id: item.id, lastCopiedAt: item.lastCopiedAt, pinOrdinal: item.pinOrdinal)
    }

    @Test(arguments: [0, 1, 129, 20_000])
    func largeCountSelectionKeepsOnlyOneExactPrefix(_ count: Int) throws {
        var selection = OrderedRetentionSelection(
            policies: HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil),
            now: Date(timeIntervalSinceReferenceDate: 30_000), protectedItemID: nil,
            projectedTotalBytes: count + 2, minimumRetiredItems: count)
        // Generate facts one at a time, without even a test-side inventory.
        for index in 0..<(count + 2) {
            if try !selection.consider(item(index)) { break }
        }
        #expect(selection.remainingRequiredItems == 0)
        #expect(selection.remainingBytes == 2)
        if count == 0 {
            #expect(selection.prefix == nil)
        } else {
            let prefix = try #require(selection.prefix)
            #expect(prefix.itemCount == count)
            #expect(prefix.canonicalBytes == count)
            #expect(prefix.revisionBytes == 0)
            #expect(prefix.through.itemID == item(count - 1).id)
            #expect(prefix.contains(summary(item(count - 1))))
            #expect(!prefix.contains(summary(item(count))))
        }
    }

    @Test
    func prefixCarriesPinAndPrimaryExclusionEvenBeforeItsCutoff() throws {
        let pinned = item(0, pinned: true, canonicalBytes: 100)
        let primary = item(1, canonicalBytes: 100)
        let oldest = item(2, canonicalBytes: 10)
        let later = item(3, canonicalBytes: 10)
        var selection = OrderedRetentionSelection(
            policies: HistoryRetentionPolicies(age: nil, storage: StorageRetention(maxTotalBytes: 210), revisions: nil),
            now: Date(timeIntervalSinceReferenceDate: 1000), protectedItemID: primary.id,
            projectedTotalBytes: 220)
        for candidate in [pinned, primary, oldest, later] {
            if try !selection.consider(candidate) { break }
        }
        let prefix = try #require(selection.prefix)
        #expect(prefix.itemCount == 1)
        #expect(prefix.excludedItemID == primary.id)
        #expect(!prefix.contains(summary(pinned)))
        #expect(!prefix.contains(summary(primary)))
        #expect(prefix.contains(summary(oldest)))
        #expect(!prefix.contains(summary(later)))
    }

    @Test
    func ageBoundaryAndIDTieBreakRemainExact() throws {
        let aged = item(1, copiedAt: 899)
        let boundary = item(2, copiedAt: 900)
        var age = OrderedRetentionSelection(
            policies: HistoryRetentionPolicies(age: AgeRetention(maxAge: 100), storage: nil, revisions: nil),
            now: Date(timeIntervalSinceReferenceDate: 1000), protectedItemID: nil, projectedTotalBytes: 2)
        #expect(try age.consider(aged))
        #expect(try !age.consider(boundary))
        #expect(age.prefix?.through.itemID == aged.id)

        let first = item(1, copiedAt: 900)
        let tied = item(2, copiedAt: 900)
        var bytes = OrderedRetentionSelection(
            policies: HistoryRetentionPolicies(age: nil, storage: StorageRetention(maxTotalBytes: 1), revisions: nil),
            now: Date(timeIntervalSinceReferenceDate: 1000), protectedItemID: nil, projectedTotalBytes: 2)
        #expect(try bytes.consider(first))
        #expect(try !bytes.consider(tied))
        #expect(bytes.prefix?.through.itemID == first.id)
    }

    @Test
    func r3ProjectedBytesSelectWhileOriginalBytesAccountForRetirement() throws {
        let oldest = item(1, canonicalBytes: 10, revisionBytes: 90)
        let later = item(2, canonicalBytes: 10)
        var selection = OrderedRetentionSelection(
            policies: HistoryRetentionPolicies(age: nil, storage: StorageRetention(maxTotalBytes: 110), revisions: nil),
            now: Date(timeIntervalSinceReferenceDate: 1000), protectedItemID: nil,
            projectedTotalBytes: 125)
        #expect(try selection.consider(oldest, projectedRevisionBytes: 5))
        #expect(try !selection.consider(later))
        let prefix = try #require(selection.prefix)
        #expect(selection.remainingBytes == 110)
        #expect(prefix.canonicalBytes == 10)
        #expect(prefix.revisionBytes == 90)
        #expect(prefix.itemCount == 1)
    }

    @Test
    func corruptOrderAndOverflowCannotProduceADestructivePrefix() throws {
        let policies = HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil)
        var order = OrderedRetentionSelection(policies: policies,
            now: Date(timeIntervalSinceReferenceDate: 1000), protectedItemID: nil,
            projectedTotalBytes: 3, minimumRetiredItems: 2)
        try order.consider(item(2))
        let before = order.prefix
        #expect(throws: DomainRejection.corruptLineage) { try order.consider(item(1)) }
        #expect(order.prefix == before)
        var overflow = OrderedRetentionSelection(policies: policies,
            now: Date(timeIntervalSinceReferenceDate: 1000), protectedItemID: nil,
            projectedTotalBytes: Int.max, minimumRetiredItems: 1)
        #expect(throws: DomainRejection.corruptLineage) {
            try overflow.consider(item(1, canonicalBytes: Int.max, revisionBytes: 1))
        }
        #expect(overflow.prefix == nil)
    }
}
