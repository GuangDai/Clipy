/// CaptureCapacityAdmissionTests — stamped-plan capacity admission at the
/// shared §9–§11 commit tail (docs/05-authority-kernel.md §16).
///
/// The physical Card 6B APFS runner (dispatch run 32632262141) proved Core
/// Data raises an uncaught `NSInternalInconsistencyException` when an
/// external-storage interim file cannot be created on a full volume, so
/// admission must refuse the typed failure before any durable write. These
/// tests pin the boundary math, the insert-refusal with durable-state
/// invariance and recovery, the byte-exact coalesce exemption, and the
/// revise refusal plus remove/clear zero-external-demand paths through the
/// same tail.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

struct CaptureCapacityAdmissionTests {
    // MARK: Boundary math

    @Test func unreadableCapacityFailsOpen() {
        #expect(CaptureCapacityAdmission.failure(
            demandBytes: 11_184_812,
            availableCapacity: nil
        ) == nil)
    }

    @Test func planWithoutNewExternalBytesIsNeverRefused() {
        #expect(CaptureCapacityAdmission.failure(
            demandBytes: 0,
            availableCapacity: 0
        ) == nil)
    }

    @Test func boundaryAdmitsExactlyAtDemandPlusMargin() {
        let demand: Int64 = 11_184_812
        #expect(CaptureCapacityAdmission.failure(
            demandBytes: demand,
            availableCapacity: demand + CaptureCapacityAdmission.marginBytes
        ) == nil)
        #expect(CaptureCapacityAdmission.failure(
            demandBytes: demand,
            availableCapacity: demand + CaptureCapacityAdmission.marginBytes - 1
        ) == .temporarilyUnavailable(.insufficientDiskSpace))
    }

    // MARK: Through the production commit tail

    @Test func insertRefusalIsTypedAndLeavesDurableStateUntouched() async throws {
        let url = WSSupport.tempStoreURL("capacity-admission-refusal")
        defer { WSSupport.removeStore(url) }

        let history = try await WSSupport.openHistory(storeURL: url)
        let authority = history.authority
        let preparation = IngestPreparationActor()
        _ = try await authority.commitCapture(try await preparation.prepare(
            WSSupport.textCapture(
                "capacity admission seed",
                observedAt: Date(timeIntervalSinceReferenceDate: 4_000)
            )
        ))
        let before = try autoreleasepool {
            try TransactionStoreSnapshot.read(from: url)
        }

        await authority.setVolumeAvailableCapacityOverride(1)
        let rejected = try await preparation.prepare(
            WSSupport.textCapture(
                "capacity admission rejected insert",
                observedAt: Date(timeIntervalSinceReferenceDate: 4_100)
            )
        )
        await #expect(
            throws: HistoryFailure.temporarilyUnavailable(.insufficientDiskSpace)
        ) {
            try await authority.commitCapture(rejected)
        }
        let after = try autoreleasepool {
            try TransactionStoreSnapshot.read(from: url)
        }
        #expect(after == before)

        // Clearing the witness restores the fail-open reader: the same
        // prepared capture commits on the healthy test volume.
        await authority.setVolumeAvailableCapacityOverride(nil)
        _ = try await authority.commitCapture(rejected)
        let recovered = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 10
        ))
        #expect(recovered.position.rawValue == 2)
        #expect(recovered.rows.map(\.title) == [
            "capacity admission rejected insert",
            "capacity admission seed"
        ])
    }

    @Test func byteExactCoalesceUnderLowCapacityStillCommits() async throws {
        let url = WSSupport.tempStoreURL("capacity-admission-coalesce")
        defer { WSSupport.removeStore(url) }

        let history = try await WSSupport.openHistory(storeURL: url)
        let authority = history.authority
        let preparation = IngestPreparationActor()
        let seedText = "capacity admission coalesce"
        let seed = try await authority.commitCapture(try await preparation.prepare(
            WSSupport.textCapture(
                seedText,
                observedAt: Date(timeIntervalSinceReferenceDate: 4_000)
            )
        ))
        guard case .committed(let seedCommit) = seed,
              case .inserted(let seedReference) = seedCommit.outcome else {
            Issue.record("seed capture did not insert")
            return
        }

        // Identical bytes coalesce to an occurrence-only update: the plan
        // carries no new external payload, so even a one-byte capacity
        // witness must not refuse it (§16).
        await authority.setVolumeAvailableCapacityOverride(1)
        let repeatReceipt = try await authority.commitCapture(
            try await preparation.prepare(
                WSSupport.textCapture(
                    seedText,
                    observedAt: Date(timeIntervalSinceReferenceDate: 4_100)
                )
            )
        )
        guard case .committed(let coalesce) = repeatReceipt,
              coalesce.position.rawValue == 2,
              case .coalesced(let winner) = coalesce.outcome,
              winner.id == seedReference.id else {
            Issue.record("low-capacity coalesce did not commit as expected")
            return
        }
        await authority.setVolumeAvailableCapacityOverride(nil)
    }

    @Test func revisionReplaceUnderInsufficientCapacityIsRefusedTyped() async throws {
        let url = WSSupport.tempStoreURL("capacity-admission-revise")
        defer { WSSupport.removeStore(url) }

        let history = try await WSSupport.openHistory(storeURL: url)
        let authority = history.authority
        let preparation = IngestPreparationActor()
        let seed = try await authority.commitCapture(try await preparation.prepare(
            WSSupport.textCapture(
                "capacity admission revise seed",
                observedAt: Date(timeIntervalSinceReferenceDate: 4_000)
            )
        ))
        guard case .committed(let seedCommit) = seed,
              case .inserted(let reference) = seedCommit.outcome else {
            Issue.record("seed capture did not insert")
            return
        }
        let before = try autoreleasepool {
            try TransactionStoreSnapshot.read(from: url)
        }

        // A replace revision appends a complete Effective Content snapshot
        // through the same `.externalStorage` column: admission must cover
        // the revise lane, not just captures (§16).
        await authority.setVolumeAvailableCapacityOverride(1)
        await #expect(
            throws: HistoryFailure.temporarilyUnavailable(.insufficientDiskSpace)
        ) {
            try await history.perform(.revise(RevisionRequest(
                itemID: reference.id,
                expected: reference.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(
                        typeIdentifier: "public.utf8-plain-text",
                        action: .replace(bytes: Data(
                            "revised under low capacity".utf8
                        ))
                    )
                ]))
            )))
        }
        let after = try autoreleasepool {
            try TransactionStoreSnapshot.read(from: url)
        }
        #expect(after == before)
        await authority.setVolumeAvailableCapacityOverride(nil)
    }

    @Test func removeAndBothClearScopesCommitUnderLowCapacity() async throws {
        let url = WSSupport.tempStoreURL("capacity-admission-delete-only")
        defer { WSSupport.removeStore(url) }

        let history = try await WSSupport.openHistory(storeURL: url)
        let authority = history.authority
        var references: [HistoryItemReference] = []
        for index in 0 ..< 3 {
            let receipt = try await history.perform(.capture(
                WSSupport.textCapture(
                    "capacity admission delete-only \(index)",
                    observedAt: Date(
                        timeIntervalSinceReferenceDate: 4_200 + Double(index)
                    )
                )
            ))
            guard case .committed(let commit) = receipt,
                  case .inserted(let reference) = commit.outcome else {
                Issue.record("delete-only arrange capture did not insert")
                return
            }
            references.append(reference)
        }
        for reference in references.prefix(2) {
            let receipt = try await history.perform(
                .placePinned(reference.id, at: .last)
            )
            guard case .committed(let commit) = receipt,
                  case .placedPinned(let placedID) = commit.outcome,
                  placedID == reference.id else {
                Issue.record("delete-only arrange pin did not commit")
                return
            }
        }

        // Remove and clear plans carry only delete/pin-compaction mutations.
        // They write no new `.externalStorage` payload and therefore must
        // remain available even when the fixed capacity witness is one byte
        // (§16). Removing the first pin also exercises the ordinal rewrite,
        // rather than only the simplest unpinned-delete plan.
        await authority.setVolumeAvailableCapacityOverride(1)

        let remove = try await history.perform(.remove(references[0].id))
        guard case .committed(let removeCommit) = remove,
              case .removed(count: 1) = removeCommit.outcome else {
            Issue.record("low-capacity pinned remove did not commit")
            return
        }
        #expect(removeCommit.position.rawValue == 6)

        let clearUnpinned = try await history.perform(.clear(.unpinned))
        guard case .committed(let unpinnedCommit) = clearUnpinned,
              case .cleared(count: 1) = unpinnedCommit.outcome else {
            Issue.record("low-capacity clear-unpinned did not commit")
            return
        }
        #expect(unpinnedCommit.position.rawValue == 7)

        let clearAll = try await history.perform(.clear(.all))
        guard case .committed(let allCommit) = clearAll,
              case .cleared(count: 1) = allCommit.outcome else {
            Issue.record("low-capacity clear-all did not commit")
            return
        }
        #expect(allCommit.position.rawValue == 8)

        let rows = try WSSupport.fetchRows(
            WSSupport.makeContainer(storeURL: url)
        )
        #expect(rows.isEmpty)
        await authority.setVolumeAvailableCapacityOverride(nil)
    }
}
