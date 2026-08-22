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
/// Every fixture drives the PUBLIC `SwiftDataHistory` over an in-memory
/// store (`HistoryPersistence.memory`, 05 §2: same Authority, planners, and
/// transaction path, no durability) — no `@testable`, because the read and
/// both writes exist on the public seam and the proof is exactly that the
/// public surface round-trips the configured policy. The writers are the
/// public retention mutations (`.setRetentionPolicy`, docs/
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
}
