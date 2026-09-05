/// Usage consumes retained scalar projections, not content lineage. Poisoned
/// blobs distinguish that contract from a full detail scan; they do not prove
/// that SwiftData avoids physically faulting external-storage attributes.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

private enum UsageFixtureDamage: Sendable, Equatable {
    case canonicalBlob
    case revisionBlob
    case negativeCanonicalBytes
    case overLimitCanonicalBytes
    case negativeRevisionBytes
    case bytesWithoutRevisions
    case unknownBytesVersion
    case missingProjection
    case orphanProjectionID
    case invalidPinOrdinal
}

struct HistoryUsageReadValidationTests {
    @Test(arguments: [UsageFixtureDamage.canonicalBlob, .revisionBlob])
    fileprivate func usageDoesNotDecodeContentBlobs(_ damage: UsageFixtureDamage) async throws {
        let (history, reference, position) = try await makeFixture()
        try await history.authority.damageUsageFixture(damage)

        let usage = try await history.usage()
        #expect(usage.position == position)
        #expect(usage.itemCount == 1)
        #expect(usage.pinnedItemCount == 0)
        #expect(usage.canonicalBytes == 5)
        #expect(usage.revisionBytes == 0)
        #expect(usage.totalContentBytes == 5)
        #expect(try await history.usage() == usage)
        #expect(try await history.authority.currentPosition() == position)

        // The damage is real: successful statistics do not declare the
        // content healthy. The ordinary lineage-reading path still fails.
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.details(for: reference.id)
        }
    }

    @Test(arguments: [
        UsageFixtureDamage.negativeCanonicalBytes,
        .overLimitCanonicalBytes,
        .negativeRevisionBytes,
        .bytesWithoutRevisions,
        .unknownBytesVersion,
        .missingProjection,
        .orphanProjectionID,
        .invalidPinOrdinal,
    ])
    fileprivate func damagedUsageFactsNeverBecomeNormalTotals(_ damage: UsageFixtureDamage) async throws {
        let (history, _, position) = try await makeFixture()
        try await history.authority.damageUsageFixture(damage)
        let failure: HistoryFailure = damage == .invalidPinOrdinal
            ? .persistence(.corruptStoredValue)
            : .persistence(.invariantViolation)

        await #expect(throws: failure) { try await history.usage() }
        #expect(try await history.authority.currentPosition() == position)
    }

    private func makeFixture() async throws -> (SwiftDataHistory, HistoryItemReference, ChangePosition) {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            "alpha", observedAt: Date(timeIntervalSinceReferenceDate: 700_060_000)
        )))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome else {
            Issue.record("Expected the five-byte usage fixture to be inserted")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return (history, reference, commit.position)
    }
}

private extension HistoryAuthority {
    /// Test-only corruption of the real, already-open in-memory store. The
    /// writable context stays inside its Authority, like the existing
    /// SignatureIndexAuthoritativeCoverageTests owner-local arrangement.
    func damageUsageFixture(_ damage: UsageFixtureDamage) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let items = try context.fetch(FetchDescriptor<HistoryItemRow>())
        let projections = try context.fetch(FetchDescriptor<RetainedBytesRow>())
        let item = try #require(items.first)
        let projection = try #require(projections.first)
        try context.transaction {
            switch damage {
            case .canonicalBlob:
                item.canonicalBlob = Data([0x01])
            case .revisionBlob:
                item.revisionStateBlob = Data([0x01])
            case .negativeCanonicalBytes:
                projection.canonicalBytes = -1
            case .overLimitCanonicalBytes:
                projection.canonicalBytes = Int.max
            case .negativeRevisionBytes:
                projection.revisionBytes = -1
            case .bytesWithoutRevisions:
                projection.revisionBytes = 1
            case .unknownBytesVersion:
                projection.bytesSchemaVersion = UInt16.max
            case .missingProjection:
                context.delete(projection)
            case .orphanProjectionID:
                // Counts remain equal. A count-only join would wrongly return
                // five bytes for a projection belonging to no retained item.
                projection.itemID = UUID()
            case .invalidPinOrdinal:
                item.pinOrdinal = -1
            }
        }
    }
}
