/// WS21Composed — Retention policy through the composed settings surface
/// (docs/06-cross-cutting.md §8 WS21; docs/02-domain.md §12; V2-02):
/// `viewState.applyMaximumUnpinnedItems(_:)` (the settings' Apply) sets a
/// satisfied value to `.unchanged`, lowers the cap to retire the excess
/// oldest unpinned items in ONE commit (`.retentionPolicySet(removedCount:)`,
/// one position advance), and the value survives a RESTART on the durable
/// singleton. The V2-02 policy bundle is applied through
/// `viewState.applyRetentionPolicies(_:)` — all-disabled lanes collapse to
/// a no-op, and an over-broad dimension rejects
/// `.invalidInput(.invalidRetentionPolicy)` with no commit.
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct WS21ComposedRetentionPolicyTests {

    /// WS21 (docs/06-cross-cutting.md §8): satisfied set → `.unchanged`;
    /// lowered set → the excess oldest unpinned retired in the same
    /// commit; restart keeps the durable policy value (05 §2: an existing
    /// store ignores the configuration's initial value).
    @Test @MainActor
    func satisfiedSetIsUnchangedLoweredSetRetiresOldestAndSurvivesRestart() async throws {
        let storeURL = ComposedSupport.tempStoreURL("ws21-composed-retention")
        defer { ComposedSupport.removeStore(storeURL) }
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL)
            )
        )
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()

        // Three unpinned items, oldest first (02 §12 eviction order).
        let base = Date(timeIntervalSinceReferenceDate: 700_202_900)
        var ids: [HistoryItemID] = []
        for (index, name) in ["alpha", "bravo", "charlie"].enumerated() {
            let receipt = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    "ws21 composed \(name)",
                    observedAt: base.addingTimeInterval(Double(index) * 100),
                    source: "com.example.ws21composed"
                )
            ))
            ids.append(
                try #require(
                    ComposedSupport.insertedReference(from: receipt, "WS21 arrange")
                ).id
            )
        }

        // Satisfied set (the Part VI default of 200): `.unchanged`, no
        // commit, no advance (02 §13) — the panel stays healthy.
        let satisfied = try await viewState.applyMaximumUnpinnedItems(200)
        guard case .unchanged = satisfied else {
            Issue.record("WS21: expected .unchanged for the satisfied set, got \(satisfied)")
            return
        }
        #expect(
            await ComposedSupport.waitFor { viewState.rows.count == 3 },
            "WS21: the satisfied set changed nothing"
        )

        // Lowered set: cap 1 retires the two OLDEST unpinned items in one
        // commit (02 §12), receipt `.retentionPolicySet(removedCount: 2)`.
        let lowered = try await viewState.applyMaximumUnpinnedItems(1)
        let commit = try #require(
            ComposedSupport.commit(of: lowered, "WS21 lowered"),
            "WS21: the lowering is a History Commit"
        )
        #expect(
            commit.position.rawValue == 4,
            "WS21: three inserts + ONE policy commit — no per-item advances"
        )
        guard case let .retentionPolicySet(removedCount) = commit.outcome else {
            Issue.record(
                "WS21: expected .retentionPolicySet(removedCount:), got \(commit.outcome)"
            )
            return
        }
        #expect(removedCount == 2, "WS21: the two oldest retired")

        // The composed panel observes the post-retention single row; the
        // survivors' order proves WHICH items retired (alpha, bravo gone).
        let retired = await ComposedSupport.waitFor { viewState.rows.count == 1 }
        #expect(retired, "WS21: the panel observes the retired set")
        #expect(viewState.rows.first?.item.id == ids[2], "WS21: charlie (newest) survives")
        for goneID in [ids[0], ids[1]] {
            do {
                _ = try await history.details(for: goneID)
                Issue.record("WS21: expected .notFound for a retired item")
            } catch let failure as HistoryFailure {
                #expect(failure == .notFound(goneID))
            }
        }

        // RESTART: the durable singleton keeps cap 1 — the configuration's
        // initial value (200) is ignored for an existing store (05 §2),
        // proven behaviorally: a fresh two-item store on the same file
        // retires one immediately.
        let restarted = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL)
            )
        )
        _ = try await restarted.perform(.capture(
            ComposedSupport.textCapture(
                "ws21 composed post-restart",
                observedAt: base.addingTimeInterval(500),
                source: "com.example.ws21composed.restart"
            )
        ))
        // Cap 1 is live: two unpinned items existed before this capture
        // (charlie + none — charlie alone), so this insert retires
        // charlie, leaving exactly one row.
        let page = try await restarted.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(
            page.rows.count == 1,
            "WS21 (05 §2): the durable cap survived the restart and stayed live"
        )
        #expect(
            !page.rows.map(\.item.id).contains(ids[2]),
            "WS21: the oldest item was retired by the restarted policy"
        )
    }

    /// WS21 + V2-02 composed (V2-02 §3.1/§8.1): the three-lane policy
    /// value through `applyRetentionPolicies` — an all-disabled bundle is
    /// a no-op (`.unchanged`), and an over-broad count dimension (0 —
    /// below the 1…100 admission range) rejects
    /// `.invalidInput(.invalidRetentionPolicy)` with no commit.
    @Test @MainActor
    func policyBundleNoOpAndInvalidDimensionRejectWithoutCommit() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()

        let insertReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws21 composed policy item",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_202_950),
                source: "com.example.ws21composed.policy"
            )
        ))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS21 policy arrange")
        )

        // All-disabled bundle: `.unchanged` — no commit, no advance.
        let disabled = try await viewState.applyRetentionPolicies(
            HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil)
        )
        guard case .unchanged = disabled else {
            Issue.record("WS21 policies: expected .unchanged, got \(disabled)")
            return
        }

        // An over-broad revision-count dimension (0 < 1): typed rejection,
        // nothing committed.
        do {
            _ = try await viewState.applyRetentionPolicies(
                HistoryRetentionPolicies(
                    age: nil,
                    storage: nil,
                    revisions: RevisionRetention(
                        maxRevisionsPerItem: 0,
                        maxRevisionBytesPerItem: nil
                    )
                )
            )
            Issue.record("WS21 policies: expected .invalidRetentionPolicy, got a receipt")
        } catch let failure as HistoryFailure {
            #expect(
                failure == .invalidInput(.invalidRetentionPolicy),
                "WS21 (V2-02 §8.3): the zero count dimension rejects, got \(failure)"
            )
        }

        // No commit, no advance: the item is intact and the position proof
        // (next commit at 2) shows neither action advanced anything.
        let details = try await viewState.details(for: inserted.id)
        #expect(details.occurrence.count == 1)
        let followUp = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws21 composed position probe",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_202_960),
                source: "com.example.ws21composed.policy"
            )
        ))
        let followUpCommit = try #require(
            ComposedSupport.commit(of: followUp, "WS21 policies position proof")
        )
        #expect(
            followUpCommit.position.rawValue == 2,
            "WS21: the no-op bundle and the rejection advanced nothing"
        )
    }
}
