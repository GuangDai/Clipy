/// ComposedRetentionLooseningTests — the Card 10 hosted journey for the
/// non-strictening retention control paths (todo-map §4.1 Card 10 row: the
/// loosen/count/storage/revision/equal controls and their hosted journey).
/// Through the REAL `SQLiteHistory` and the same `HistoryViewState` seams
/// the Settings scene calls:
///
/// - every control (count, age, storage, revision count/bytes) applies
///   through the public mutation intents;
/// - loosening and disabling commit DIRECTLY with a zero-effect receipt —
///   the draft layer proves no confirmation gates them
///   (`RetentionSettingsDraftTests`), the running-app R1 journey proves the
///   sheet stays closed (`RetentionPolicyJourneyUITests`), and this suite
///   proves the committed values persist and read back exactly through the
///   authoritative configured-policy read (DEC-RET-READ);
/// - re-applying the persisted value is a true no-op: `.unchanged`, no
///   History Commit, no `ChangePosition` advance (02 §8/§12; V2-02
///   §4.4/§5.6).
///
/// Durability/restart semantics stay with `RetentionConfigurationReadTests`
/// and WS21; this suite owns the Settings control-path coverage only.
import Foundation
import HistoryCore
import HistoryStorage
@testable import ClipyApp
import Testing

struct ComposedRetentionLooseningTests {

    @Test @MainActor
    func everyControlAppliesLoosensAndReadsBackWithEqualValuesAsNoOps() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)

        // Two tiny items captured now: every limit set below is satisfied,
        // so each committed receipt reports zero removals (03a §6) and no
        // item is retired by R1/R2/R3.
        for (index, name) in ["alpha", "bravo"].enumerated() {
            _ = try await history.perform(.capture(ComposedSupport.textCapture(
                "clipy-composed-loosen-\(name)",
                observedAt: Date().addingTimeInterval(Double(index)),
                source: "com.example.composed.loosening"
            )))
        }

        // Count control (the v1 `.setRetentionPolicy` seam, V2-02 §8.1):
        // tighten to the satisfied 2, loosen 2 → 5, then re-apply the
        // persisted 5 — the equal re-apply never writes (02 §8/§12).
        let tightenedCount = try await viewState.applyMaximumUnpinnedItems(2)
        expectCountCommit(tightenedCount, position: 3, "count tighten")
        let loosenedCount = try await viewState.applyMaximumUnpinnedItems(5)
        expectCountCommit(loosenedCount, position: 4, "count loosen")
        let equalCount = try await viewState.applyMaximumUnpinnedItems(5)
        expectUnchanged(equalCount, "count equal re-apply")

        // Policy controls (a set replaces the whole policy value, exactly
        // like the draft's Apply): enable age at 30 days, loosen it to 45,
        // enable storage, loosen it, enable both revision thresholds,
        // loosen the count, then disable age. Every step commits directly
        // with a zero-effect receipt.
        let ageEnabled = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 2_592_000),
                storage: nil,
                revisions: nil
            )
        )
        expectPoliciesCommit(ageEnabled, position: 5, "age enable")
        let ageLoosened = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 3_888_000),
                storage: nil,
                revisions: nil
            )
        )
        expectPoliciesCommit(ageLoosened, position: 6, "age loosen")
        let storageEnabled = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 3_888_000),
                storage: StorageRetention(maxTotalBytes: 67_108_864),
                revisions: nil
            )
        )
        expectPoliciesCommit(storageEnabled, position: 7, "storage enable")
        let storageLoosened = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 3_888_000),
                storage: StorageRetention(maxTotalBytes: 134_217_728),
                revisions: nil
            )
        )
        expectPoliciesCommit(storageLoosened, position: 8, "storage loosen")
        let revisionsEnabled = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 3_888_000),
                storage: StorageRetention(maxTotalBytes: 134_217_728),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 20,
                    maxRevisionBytesPerItem: 67_108_864
                )
            )
        )
        expectPoliciesCommit(revisionsEnabled, position: 9, "revision enable")
        let revisionsLoosened = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 3_888_000),
                storage: StorageRetention(maxTotalBytes: 134_217_728),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 40,
                    maxRevisionBytesPerItem: 67_108_864
                )
            )
        )
        expectPoliciesCommit(revisionsLoosened, position: 10, "revision loosen")
        let ageDisabled = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: nil,
                storage: StorageRetention(maxTotalBytes: 134_217_728),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 40,
                    maxRevisionBytesPerItem: 67_108_864
                )
            )
        )
        expectPoliciesCommit(ageDisabled, position: 11, "age disable")
        let equalPolicies = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: nil,
                storage: StorageRetention(maxTotalBytes: 134_217_728),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 40,
                    maxRevisionBytesPerItem: 67_108_864
                )
            )
        )
        expectUnchanged(equalPolicies, "policy equal re-apply")

        // The authoritative configured read (the Retention tab's panel-open
        // read) reflects the last committed values exactly.
        let configuration = try await viewState.retentionConfiguration()
        #expect(configuration.maximumUnpinnedItems == 5)
        #expect(
            configuration.policies == HistoryRetentionPolicies(
                age: nil,
                storage: StorageRetention(maxTotalBytes: 134_217_728),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 40,
                    maxRevisionBytesPerItem: 67_108_864
                )
            )
        )

        // Position proof: the two equal re-applies advanced nothing — the
        // next durable mutation is position 12 — and every captured item
        // survived the satisfied limit changes.
        let probe = try await history.perform(.capture(ComposedSupport.textCapture(
            "clipy-composed-loosen-probe",
            observedAt: Date().addingTimeInterval(2),
            source: "com.example.composed.loosening"
        )))
        let probeCommit = try #require(
            ComposedSupport.commit(of: probe, "position proof capture")
        )
        #expect(
            probeCommit.position.rawValue == 12,
            "the equal re-applies produced no History Commit"
        )
        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(page.rows.count == 3, "all captured items survive")
    }

    @Test @MainActor
    func revisionBytesLoosenAndEveryDisableCommitDirectlyWithExactReadback() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)

        // The Batch 39 ceiling's remaining cells: a revision-bytes loosen
        // and the storage/revision-count/revision-bytes disables — each a
        // direct commit with a zero-effect receipt, an exact authoritative
        // readback, and a final equal re-apply that advances nothing.
        for (index, name) in ["alpha", "bravo"].enumerated() {
            _ = try await history.perform(.capture(ComposedSupport.textCapture(
                "clipy-composed-disable-\(name)",
                observedAt: Date().addingTimeInterval(Double(index)),
                source: "com.example.composed.disabling"
            )))
        }

        let allEnabled = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 2_592_000),
                storage: StorageRetention(maxTotalBytes: 67_108_864),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 20,
                    maxRevisionBytesPerItem: 67_108_864
                )
            )
        )
        expectPoliciesCommit(allEnabled, position: 3, "all four enabled")

        let revisionBytesLoosened = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 2_592_000),
                storage: StorageRetention(maxTotalBytes: 67_108_864),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 20,
                    maxRevisionBytesPerItem: 134_217_728
                )
            )
        )
        expectPoliciesCommit(revisionBytesLoosened, position: 4, "revision bytes loosen")

        let storageDisabled = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 2_592_000),
                storage: nil,
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 20,
                    maxRevisionBytesPerItem: 134_217_728
                )
            )
        )
        expectPoliciesCommit(storageDisabled, position: 5, "storage disable")

        let revisionCountDisabled = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 2_592_000),
                storage: nil,
                revisions: RevisionRetention(
                    maxRevisionsPerItem: nil,
                    maxRevisionBytesPerItem: 134_217_728
                )
            )
        )
        expectPoliciesCommit(revisionCountDisabled, position: 6, "revision count disable")

        let revisionBytesDisabled = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 2_592_000),
                storage: nil,
                revisions: nil
            )
        )
        expectPoliciesCommit(revisionBytesDisabled, position: 7, "revision bytes disable")

        let equalReapply = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 2_592_000),
                storage: nil,
                revisions: nil
            )
        )
        expectUnchanged(equalReapply, "disable-tail equal re-apply")

        let configuration = try await viewState.retentionConfiguration()
        #expect(
            configuration.policies == HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 2_592_000),
                storage: nil,
                revisions: nil
            ),
            "the authoritative read reflects the disable tail exactly"
        )

        // The equal re-apply advanced nothing: the next durable mutation
        // lands at position 8, and both captured items survived.
        let probe = try await history.perform(.capture(ComposedSupport.textCapture(
            "clipy-composed-disable-probe",
            observedAt: Date().addingTimeInterval(2),
            source: "com.example.composed.disabling"
        )))
        let probeCommit = try #require(
            ComposedSupport.commit(of: probe, "position proof capture")
        )
        #expect(
            probeCommit.position.rawValue == 8,
            "the equal re-apply produced no History Commit"
        )
        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(page.rows.count == 3, "all captured items survive")
    }

    /// A committed `.setRetentionPolicy` receipt with zero removals at the
    /// expected position, or a recorded issue (03a §6).
    private func expectCountCommit(
        _ receipt: HistoryReceipt,
        position: UInt64,
        _ clause: String
    ) {
        guard case .committed(let commit) = receipt else {
            Issue.record("\(clause): expected .committed, got \(receipt)")
            return
        }
        #expect(
            commit.position.rawValue == position,
            "\(clause): one position advance for the policy commit"
        )
        guard case .retentionPolicySet(removedCount: let removedCount)
                = commit.outcome else {
            Issue.record(
                "\(clause): expected .retentionPolicySet, got \(commit.outcome)"
            )
            return
        }
        #expect(
            removedCount == 0,
            "\(clause): the satisfied count removes nothing"
        )
    }

    /// A committed `.setRetentionPolicies` receipt with zero retirements
    /// and zero prunes at the expected position, or a recorded issue
    /// (03a §6; `V2-02` §8.1).
    private func expectPoliciesCommit(
        _ receipt: HistoryReceipt,
        position: UInt64,
        _ clause: String
    ) {
        guard case .committed(let commit) = receipt else {
            Issue.record("\(clause): expected .committed, got \(receipt)")
            return
        }
        #expect(
            commit.position.rawValue == position,
            "\(clause): one position advance for the policy commit"
        )
        guard case .retentionPoliciesSet(
            retiredItems: let retiredItems,
            prunedRevisions: let prunedRevisions
        ) = commit.outcome else {
            Issue.record(
                "\(clause): expected .retentionPoliciesSet, got \(commit.outcome)"
            )
            return
        }
        #expect(
            retiredItems == 0 && prunedRevisions == 0,
            "\(clause): the satisfied policies retire and prune nothing"
        )
    }

    /// A no durable mutation receipt, or a recorded issue (03a §6).
    private func expectUnchanged(_ receipt: HistoryReceipt, _ clause: String) {
        guard case .unchanged = receipt else {
            Issue.record("\(clause): expected .unchanged, got \(receipt)")
            return
        }
    }
}
