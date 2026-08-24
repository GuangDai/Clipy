/// SPEC-IMPL-003 proof — the authoritative configured-policy READ
/// (`ClipboardHistory.retentionConfiguration()`, docs/v2/V2-07-ux.md §5.2
/// "the settings panel shows the configured budget" and §6.3's panel-open
/// one-shot read per §4.2.2; audit: docs/reviews/
/// 2026-08-20-clipy-maccy-audit/02-spec-implementation.md SPEC-IMPL-003).
/// The seam returns the persisted CONFIGURED retention state — the v1 count
/// from the position singleton (docs/05-authority-kernel.md §3.2) plus the
/// V2-02 dimensions from the retention-expansion config singleton (`V2-02`
/// §3.3) — and never a live current-retained-bytes usage value, which the
/// public surface deliberately does not expose (V2-07 §2.2 OPEN-2).
///
/// The ordinary fixtures drive the PUBLIC `SwiftDataHistory` over an
/// in-memory store (`HistoryPersistence.memory`, 05 §2: same Authority,
/// planners, and transaction path, no durability). `RET-READ-1A` additionally
/// releases a first owner and reopens a persistent store through the same
/// public seam. There is no `@testable` import: the read and both writes exist
/// on the public seam and the proof is exactly that the configured policy
/// round-trips without a row-level oracle. The writers are the public
/// retention mutations (`.setRetentionPolicy`, docs/
/// 03a-instruction-set.md §5; `.setRetentionPolicies`, `V2-02` §8.1 — a set
/// replaces the WHOLE policy value); the read-back assertions use the spec
/// literals, not the implementation constants.
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct RetentionConfigurationReadTests {

    /// Opens the real facade over an in-memory store (05 §2) with the given
    /// initial count — the Part VI default (200, 06 §2) unless overridden.
    private func openMemoryHistory(
        initialMaximumUnpinnedItems: Int = 200
    ) async throws -> SwiftDataHistory {
        try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(
                persistence: .memory,
                initialMaximumUnpinnedItems: initialMaximumUnpinnedItems
            )
        )
    }

    /// A new store reads back the v1-faithful defaults: the `open`-time
    /// initial count (the Part VI default 200, 06 §2 — written to the
    /// position singleton at bootstrap, 05 §13) and every V2-02 dimension
    /// disabled (`V2-02` §3.3's all-disabled bootstrap row).
    @Test func newStoreReadsBackTheDefaultConfiguration() async throws {
        let history = try await openMemoryHistory()

        let configuration = try await history.retentionConfiguration()

        #expect(configuration.maximumUnpinnedItems == 200)
        #expect(configuration.policies.age == nil)
        #expect(configuration.policies.storage == nil)
        #expect(configuration.policies.revisions == nil)
    }

    /// The read returns the PERSISTED configured policy, not the `open`
    /// configuration's initial value: after the public mutations commit,
    /// the read reports the mutated count (05 §2/§13 — the initial value is
    /// ignored once the singleton exists) and the exact V2-02 dimensions
    /// the `.setRetentionPolicies` stamping persisted (`V2-02` §5.6).
    @Test func readReturnsThePersistedConfiguredPolicyAfterMutations() async throws {
        let history = try await openMemoryHistory()

        // v1 count dimension: 200 → 42 (03a §5; receipt 03a §6).
        let countReceipt = try await history.perform(
            .setRetentionPolicy(maximumUnpinnedItems: 42)
        )
        guard case .committed = countReceipt else {
            Issue.record("SPEC-IMPL-003: expected .committed for the count set, got \(countReceipt)")
            return
        }

        // V2-02 dimensions: age 30 d (2,592,000 s), storage 500 MiB
        // (524,288,000 bytes), revisions 20 / 64 MiB — all inside the §8.3
        // admission ranges.
        let policies = HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 30 * 86_400),
            storage: StorageRetention(maxTotalBytes: 500 * 1_048_576),
            revisions: RevisionRetention(
                maxRevisionsPerItem: 20,
                maxRevisionBytesPerItem: 64 * 1_048_576
            )
        )
        let policyReceipt = try await history.perform(.setRetentionPolicies(policies))
        guard case .committed = policyReceipt else {
            Issue.record("SPEC-IMPL-003: expected .committed for the policy set, got \(policyReceipt)")
            return
        }

        let configuration = try await history.retentionConfiguration()
        #expect(configuration.maximumUnpinnedItems == 42)
        #expect(configuration.policies == policies)
    }

    /// A disabled dimension reads back as `nil` — its dormant stored value
    /// is never exposed as a policy (`V2-02` §3.3) — and the R3 thresholds
    /// are independently optional (`V2-02` §2.1): a count-only revision
    /// policy round-trips with its byte threshold `nil`.
    @Test func disabledDimensionsReadBackNilAndRevisionThresholdsAreIndependent() async throws {
        let history = try await openMemoryHistory()

        let policies = HistoryRetentionPolicies(
            age: nil,
            storage: StorageRetention(maxTotalBytes: 128 * 1_048_576),
            revisions: RevisionRetention(
                maxRevisionsPerItem: 5,
                maxRevisionBytesPerItem: nil
            )
        )
        let setReceipt = try await history.perform(.setRetentionPolicies(policies))
        guard case .committed = setReceipt else {
            Issue.record("SPEC-IMPL-003: expected .committed for the partial policy set, got \(setReceipt)")
            return
        }

        let configuration = try await history.retentionConfiguration()
        #expect(configuration.policies == policies)
        #expect(configuration.policies.age == nil)
        #expect(configuration.policies.revisions?.maxRevisionBytesPerItem == nil)

        // Re-disabling every dimension reads back all-nil again: the §3.1
        // normalization and the disabled-lane mapping (`V2-02` §3.3) leave
        // no dormant value visible on the read.
        let cleared = HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil)
        let clearReceipt = try await history.perform(.setRetentionPolicies(cleared))
        guard case .committed = clearReceipt else {
            Issue.record("SPEC-IMPL-003: expected .committed for the policy clear, got \(clearReceipt)")
            return
        }
        let clearedConfiguration = try await history.retentionConfiguration()
        #expect(clearedConfiguration.policies == cleared)
    }

    /// The read is the value a later set compares against (05 §3.2; `V2-02`
    /// §3.3): re-applying exactly the read-back configuration is the
    /// satisfied-value no-op (docs/02-domain.md §12/§13) — no commit, no
    /// position advance, no retirement. This is the settings surface's
    /// "Apply unchanged" safety property (SPEC-IMPL-003): an Apply that
    /// starts from the authoritative read can never silently wipe a real
    /// persisted policy.
    @Test func reapplyingTheReadBackConfigurationIsUnchanged() async throws {
        let history = try await openMemoryHistory()

        let policies = HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 7 * 86_400),
            storage: nil,
            revisions: RevisionRetention(
                maxRevisionsPerItem: nil,
                maxRevisionBytesPerItem: 16 * 1_048_576
            )
        )
        _ = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 150))
        _ = try await history.perform(.setRetentionPolicies(policies))

        let configuration = try await history.retentionConfiguration()

        // The count read-back re-set is `.unchanged` (02 §12's satisfied
        // value; the WS21 no-op posture).
        let countReceipt = try await history.perform(
            .setRetentionPolicy(maximumUnpinnedItems: configuration.maximumUnpinnedItems)
        )
        guard case .unchanged = countReceipt else {
            Issue.record("SPEC-IMPL-003: expected .unchanged re-setting the read-back count, got \(countReceipt)")
            return
        }
        // The V2-02 read-back re-set is `.unchanged` (the R.6 same-value
        // satisfied no-op, `V2-02` §8.3).
        let policyReceipt = try await history.perform(
            .setRetentionPolicies(configuration.policies)
        )
        guard case .unchanged = policyReceipt else {
            Issue.record("SPEC-IMPL-003: expected .unchanged re-setting the read-back policies, got \(policyReceipt)")
            return
        }
    }

    /// RET-READ-1A: configured retention is durable History state, not UI-
    /// held defaults. The first facade and all six actor owners leave scope;
    /// a second public open must return the literal awkward-unit values. Both
    /// setters then consume that read value as satisfied state: no History
    /// Commit, no position advance, and no retained-row change (`V2-02`
    /// §8.1/§12; `04` Red 10A).
    @Test("released owner reopens exact configuration and readback reapplies unchanged")
    func persistentReadbackSurvivesOwnerReleaseAndReappliesUnchanged() async throws {
        let storeURL = WSSupport.tempStoreURL("ret-read-owner-release")
        defer { WSSupport.removeStore(storeURL) }

        let retainedID = try await Self.seedFirstOwner(at: storeURL)

        let reopened = try await WSSupport.openHistory(storeURL: storeURL)
        let configuration = try await reopened.retentionConfiguration()

        #expect(configuration.maximumUnpinnedItems == 37)
        #expect(configuration.policies.age?.maxAge == 90_001)
        #expect(configuration.policies.storage?.maxTotalBytes == 1_048_577)
        #expect(configuration.policies.revisions?.maxRevisionsPerItem == 19)
        #expect(configuration.policies.revisions?.maxRevisionBytesPerItem == 1_048_577)

        let before = try await reopened.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(before.position.rawValue == 4)
        #expect(before.rows.map(\.item.id) == [retainedID])
        #expect(before.rows.map(\.title) == ["RET-READ-1A retained payload"])

        let countReceipt = try await reopened.perform(
            .setRetentionPolicy(
                maximumUnpinnedItems: configuration.maximumUnpinnedItems
            )
        )
        guard case .unchanged = countReceipt else {
            Issue.record(
                "RET-READ-1A: expected unchanged count readback, got \(countReceipt)"
            )
            return
        }

        let policiesReceipt = try await reopened.perform(
            .setRetentionPolicies(configuration.policies)
        )
        guard case .unchanged = policiesReceipt else {
            Issue.record(
                "RET-READ-1A: expected unchanged policy readback, got \(policiesReceipt)"
            )
            return
        }

        let after = try await reopened.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(after.position == before.position)
        #expect(after.rows.map(\.item.id) == before.rows.map(\.item.id))
        #expect(after.rows.map(\.title) == before.rows.map(\.title))
    }

    /// Returns only an immutable business ID, so the first facade, Authority,
    /// worker actors, and ModelContainer are all released before reopen.
    private static func seedFirstOwner(
        at storeURL: URL
    ) async throws -> HistoryItemID {
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let captureReceipt = try await history.perform(.capture(
            WSSupport.textCapture(
                "RET-READ-1A retained payload",
                observedAt: Date(timeIntervalSinceReferenceDate: 800_000_001)
            )
        ))
        guard case let .committed(captureCommit) = captureReceipt,
              case let .inserted(item) = captureCommit.outcome else {
            Issue.record("RET-READ-1A: expected the seed capture to insert")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(captureCommit.position.rawValue == 1)

        // Pin the retained oracle before enabling the deliberately short,
        // awkward age policy. The fixed capture timestamp can then remain
        // deterministic while the row is protected by the product's pinned
        // retention invariant rather than by wall-clock proximity.
        let pinReceipt = try await history.perform(.placePinned(item.id, at: .first))
        guard case let .committed(pinCommit) = pinReceipt else {
            Issue.record("RET-READ-1A: expected the retained oracle pin to commit")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(pinCommit.position.rawValue == 2)

        let countReceipt = try await history.perform(
            .setRetentionPolicy(maximumUnpinnedItems: 37)
        )
        guard case let .committed(countCommit) = countReceipt else {
            Issue.record("RET-READ-1A: expected the count configuration to commit")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(countCommit.position.rawValue == 3)

        let policiesReceipt = try await history.perform(.setRetentionPolicies(
            HistoryRetentionPolicies(
                age: AgeRetention(maxAge: 90_001),
                storage: StorageRetention(maxTotalBytes: 1_048_577),
                revisions: RevisionRetention(
                    maxRevisionsPerItem: 19,
                    maxRevisionBytesPerItem: 1_048_577
                )
            )
        ))
        guard case let .committed(policiesCommit) = policiesReceipt else {
            Issue.record("RET-READ-1A: expected the expansion configuration to commit")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(policiesCommit.position.rawValue == 4)
        return item.id
    }
}
