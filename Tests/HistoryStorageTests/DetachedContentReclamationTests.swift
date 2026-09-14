import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// Logical History commits are immediate and atomic. Only unreachable
/// payload storage drains across physical batches, without extra commits.
struct DetachedContentReclamationTests {
    @Test func clearCommitsBeforePayloadReclamationAndEachPhysicalBatchIsBounded() async throws {
        let history = try await fixture()
        let before = try await counts(history)
        #expect(before.representations == 96)
        let gate = SuspensionGate()
        await parkCleanup(history, gate)
        let receipt = try await history.perform(.clear(.all))
        let commit = try #require(receipt.commit)
        await gate.waitForPark(AuthoritySuspensionPoint.blobCleanupBatchEntry.rawValue)
        do {
            let detached = try await counts(history)
            #expect(detached.items == 0)
            #expect(detached.contents == before.contents)
            #expect(detached.representations == before.representations)
            #expect(detached.position == commit.position.rawValue)
            #expect(detached.journalCount == before.journalCount + 1)
            #expect(try await history.browse(.init(kind: .recent, limit: 1)).rows.isEmpty)
            #expect(try await history.usage().canonicalBytes == 0)

            // Exactly one physical batch, then pause again before another
            // can run. It may reclaim only 32 representation rows.
            await gate.resume(AuthoritySuspensionPoint.blobCleanupBatchEntry.rawValue)
            await gate.waitForPark(AuthoritySuspensionPoint.blobCleanupBatchEntry.rawValue)
            let partial = try await counts(history)
            #expect(partial.representations == 64)
            #expect(partial.position == detached.position)
            #expect(partial.journalCount == detached.journalCount)
            await resumeCleanup(history, gate)
            await history.authority.waitForBlobCleanup()
            let finished = try await counts(history)
            #expect(finished.contents == 0 && finished.representations == 0)
            #expect(finished.position == detached.position)
            #expect(finished.journalCount == detached.journalCount)
        } catch {
            await resumeCleanup(history, gate)
            throw error
        }
    }

    @Test func failedLogicalRetirementDoesNotDetachAnyPayload() async throws {
        let history = try await fixture()
        let before = try await counts(history)
        let gate = SuspensionGate()
        await parkCleanup(history, gate)
        await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.perform(.clear(.all))
        }
        #expect(try await counts(history) == before)
        #expect(try await history.browse(.init(kind: .recent, limit: 1)).rows.count == 1)
        await resumeCleanup(history, gate)
    }

    @Test func reopenResumesCancelledPhysicalReclamationWithoutAnotherHistoryCommit() async throws {
        let url = WSSupport.tempStoreURL("detached-reclamation-reopen")
        defer { WSSupport.removeStore(url) }
        let committed = try await createClosedDetachedStore(url)
        #expect(committed.contents > 0 && committed.representations > 0)
        let reopened = try await WSSupport.openHistory(storeURL: url)
        #expect(try await reopened.browse(.init(kind: .recent, limit: 1)).rows.isEmpty)
        await reopened.authority.waitForBlobCleanup()
        let reclaimed = try await counts(reopened)
        #expect(reclaimed.contents == 0 && reclaimed.representations == 0)
        #expect(reclaimed.position == committed.position)
        #expect(reclaimed.journalCount == committed.journalCount)
    }

    @Test func detachedOwnerIDCannotReconnectOldCanonicalContentBeforeCleanup() async throws {
        let history = try await WSSupport.makeHistory()
        let captured = try await history.perform(.capture(WSSupport.textCapture(
            "old private payload", observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )))
        guard let commit = captured.commit, case .inserted(let item) = commit.outcome else {
            Issue.record("Expected fixture capture"); return
        }
        await history.authority.waitForBlobCleanup()
        let gate = SuspensionGate()
        await parkCleanup(history, gate)
        do {
            _ = try await history.perform(.remove(item.id))
            let before = try await counts(history)
            let preparation = IngestPreparationActor(makeCandidateID: { item.id })
            let candidate = try await preparation.prepare(WSSupport.textCapture(
                "different new payload", observedAt: Date(timeIntervalSinceReferenceDate: 2)
            ))
            await #expect(throws: CaptureCandidateIDCollision.self) {
                try await history.authority.commitCapture(candidate)
            }
            #expect(try await counts(history) == before)
            #expect(try await history.browse(.init(kind: .recent, limit: 1)).rows.isEmpty)
            await resumeCleanup(history, gate)
        } catch {
            await resumeCleanup(history, gate)
            throw error
        }
    }

    private func createClosedDetachedStore(_ url: URL) async throws -> Counts {
        let history = try await WSSupport.openHistory(storeURL: url)
        try await populate(history)
        let gate = SuspensionGate()
        await parkCleanup(history, gate)
        _ = try await history.perform(.clear(.all))
        await gate.waitForPark(AuthoritySuspensionPoint.blobCleanupBatchEntry.rawValue)
        let task = await history.authority.blobCleanupTask
        await history.authority.cancelBlobCleanup()
        await resumeCleanup(history, gate)
        await task?.value
        return try await counts(history)
    }

    private func fixture() async throws -> SQLiteHistory {
        let history = try await WSSupport.makeHistory()
        try await populate(history)
        return history
    }

    private func populate(_ history: SQLiteHistory) async throws {
        let representations = (0..<32).map { index in
            CapturedRepresentation(typeIdentifier: "org.clipy.reclamation.\(index)", bytes: Data(repeating: UInt8(index), count: 1024))
        }
        let captured = try await history.perform(.capture(ClipboardCapture(
            representations: representations, origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 100)
        )))
        guard let commit = captured.commit, case .inserted(let reference) = commit.outcome else {
            Issue.record("Expected fixture capture"); return
        }
        for version in 1...2 {
            _ = try await history.perform(.revise(RevisionRequest(
                itemID: reference.id, expected: ContentVersion(rawValue: UInt64(version)),
                intent: .replace(RevisionDraft(decisions: representations.enumerated().map { index, representation in
                    RevisionDecision(typeIdentifier: representation.typeIdentifier,
                                     action: .replace(bytes: Data(repeating: UInt8(index + version), count: 1024)))
                }))
            )))
        }
        await history.authority.waitForBlobCleanup()
    }

    private struct Counts: Equatable, Sendable {
        let items: Int64
        let contents: Int64
        let representations: Int64
        let detached: Int64
        let position: UInt64
        let journalCount: Int64
    }

    private func counts(_ history: SQLiteHistory) async throws -> Counts {
        try await history.authority.withTestDatabase { authority in
            let row = try authority.database.prepare("""
                SELECT (SELECT count(*) FROM history_items), (SELECT count(*) FROM contents),
                    (SELECT count(*) FROM representations),
                    (SELECT count(*) FROM contents c WHERE NOT EXISTS(SELECT 1 FROM history_items h WHERE h.id=c.itemID)),
                    changePosition, (SELECT count(*) FROM history_change_records)
                FROM history_state WHERE key='retained-history'
                """)
            defer { row.finalize() }
            #expect(try row.step())
            return try Counts(items: row.integer(at: 0), contents: row.integer(at: 1),
                              representations: row.integer(at: 2), detached: row.integer(at: 3),
                              position: sqliteUInt64(row.blob(at: 4)), journalCount: row.integer(at: 5))
        }
    }

    private func parkCleanup(_ history: SQLiteHistory, _ gate: SuspensionGate) async {
        await history.authority.setSuspensionHandler { point in
            if point == .blobCleanupBatchEntry { await gate.park(at: point.rawValue) }
        }
    }

    private func resumeCleanup(_ history: SQLiteHistory, _ gate: SuspensionGate) async {
        await history.authority.setSuspensionHandler(nil)
        await gate.resumeAll()
    }
}

private extension HistoryReceipt {
    var commit: HistoryCommit? {
        guard case .committed(let commit) = self else { return nil }
        return commit
    }
}
