import Foundation
import HistoryCore
import Synchronization
import Testing
@testable import HistoryStorage

struct AuthorityMutationRegressionTests {
    @Test func unpinnedRemovalDoesNotInspectAnUnrelatedPinnedLane() async throws {
        let history = try await WSSupport.makeHistory()
        let pinned = try await RetainedBytesTestSupport.capture("pinned", in: history)
        let unpinned = try await RetainedBytesTestSupport.capture("unpinned", in: history)
        _ = try await history.perform(.placePinned(pinned.id, at: .first))
        try await history.authority.withTestDatabase { authority in
            // This unrelated lane has a hole. Reading/reordering a pinned
            // target must reject it; unpinned removal has no pin effect.
            try authority.database.execute("UPDATE history_items SET pinOrdinal=2 WHERE id=?",
                                           bindings: [.text(pinned.id.rawValue.uuidString)])
        }
        let missing = HistoryItemID(rawValue: UUID())
        await #expect(throws: HistoryFailure.notFound(missing)) {
            try await history.perform(.remove(missing))
        }
        let receipt = try await history.perform(.remove(unpinned.id))
        guard case .committed(let commit) = receipt, case .removed(count: 1) = commit.outcome else {
            Issue.record("Expected an unpinned point removal to commit")
            return
        }
        #expect(try await history.usage().itemCount == 1)
        #expect(try await history.pastePayload(for: pinned.id).item == pinned)
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try await history.perform(.remove(pinned.id))
        }
    }

    @Test func metadataOnlyCommitsDoNotQueryVolumeCapacity() async throws {
        let capacityReads = Mutex(0)
        let authority = try HistoryAuthority(
            storeLocation: HistoryStoreLocation(persistence: .temporary),
            volumeAvailableCapacityReader: {
                capacityReads.withLock { $0 += 1 }
                return nil
            }
        )
        try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        let preparation = IngestPreparationActor()
        let capture = try await preparation.prepare(WSSupport.textCapture(
            "capacity probe", observedAt: Date(timeIntervalSinceReferenceDate: 900_000_000)
        ))
        _ = try await authority.commitCapture(capture)
        #expect(capacityReads.withLock { $0 } == 1)

        _ = try await authority.commitCapture(capture)
        _ = try await authority.commitPinnedPlacement(capture.domain.candidateID, .last)
        _ = try await authority.commitUnpin(capture.domain.candidateID)
        _ = try await authority.commitRetentionPolicy(nil)
        _ = try await authority.commitRemove(capture.domain.candidateID)
        #expect(capacityReads.withLock { $0 } == 1)
    }

    @Test func revisionCannotOverflowTheAggregateWhenStorageRetentionIsDisabled() async throws {
        let history = try await WSSupport.makeHistory()
        let item = try await RetainedBytesTestSupport.capture("canonical", in: history)
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("""
                UPDATE history_state SET canonicalBytes=1,revisionBytes=?
                WHERE key='retained-history'
                """, bindings: [.integer(Int64.max - 1)])
        }
        let before = try await history.usage()
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try await history.perform(.revise(RevisionRequest(
                itemID: item.id, expected: item.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data("revision".utf8))),
                ]))
            )))
        }
        #expect(try await history.usage() == before)
        let payload = try await history.pastePayload(for: item.id)
        #expect(payload.item == item)
        #expect(payload.representations.map(\.bytes) == [Data("canonical".utf8)])
    }
}
