/// retentionConfiguration read path — the authoritative configured-policy
/// read backing `ClipboardHistory.retentionConfiguration()`.
/// Owning spec: docs/v2/V2-07-ux.md §5.2 (the settings panel shows the
/// CONFIGURED budget) and §6.3 (each settings section renders from the
/// capability's status value on panel-open — a one-shot read per §4.2.2);
/// read-path discipline: docs/05-authority-kernel.md §14 (one operation-local
/// context, one non-suspending interval, §5); audit: docs/reviews/
/// 2026-08-20-clipy-maccy-audit/02-spec-implementation.md SPEC-IMPL-003.
/// Split out of RetentionPolicySweep.swift (file-concern hygiene: that file
/// owns the R.6 mutation sweep; this file owns the read); same target,
/// no semantics shared.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

extension HistoryAuthority {
    // MARK: - Configured-policy read (V2-07 §5.2/§6.3)

    /// Reads the persisted configured retention state — the v1 count from
    /// the position singleton (05 §3.2) and the V2-02 dimensions from the
    /// retention-expansion config singleton (`V2-02` §3.3) — inside ONE
    /// serialized, non-suspending Authority interval (§5), so the two halves
    /// of the unified settings group (V2-07 §6.3) can never be read from
    /// different commits.
    ///
    /// This is a configured-POLICY read only: no retained-byte usage scalar
    /// is fetched or returned (V2-07 §2.2 OPEN-2 — a live usage read is not
    /// on the public surface; the `RetainedBytesRow` projection is a
    /// planner-internal fact, `V2-02` §3.2).
    ///
    /// Flow mirrors `currentPosition()`: operation-local context → singleton
    /// fetches → fail-closed validation → value assembly, with no `await`
    /// past context creation (§5) and no test suspension point (no walking-
    /// skeleton gate interleaves this read; the WS12 harness drives only the
    /// browse/search/position-recheck seams).
    ///
    /// - Throws: `.temporarilyUnavailable(.factProof)` when a singleton fetch
    ///   cannot complete; `.persistence(.invariantViolation)` for an absent
    ///   or duplicated singleton mid-run; `.persistence(.corruptStoredValue)`
    ///   for an out-of-range stored count (§16, D19) or an unknown
    ///   `configSchemaVersion` / non-finite `ageMaxSeconds` (`V2-02` §3.3,
    ///   DC-21); `.persistence(.invariantViolation)` for an out-of-range or
    ///   contradictory config combination (`V2-02` §8.3). A corrupted
    ///   singleton fails CLOSED — the read never substitutes a default value
    ///   for an unreadable policy (05 §13's no-silent-repair stance).
    internal func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending read interval (§5): no `await` past this
        //    line while the context is live. ──

        // The v1 count dimension: `decodePositionRow` re-validates the stored
        // value against the fixed Part VI user range and fails closed as
        // `.persistence(.corruptStoredValue)` (§16) — the same fail-closed
        // read every other consumer of the singleton performs.
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (_, currentPolicy) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // The V2-02 dimensions: the SHARED fetch/validate/map core the
        // capture/revise/sweep lanes plan with
        // (`RetentionConfigLoading.loadValidatedPolicies`), so a config row
        // corrupted after `open` fails closed here with the exact same typed
        // failures the mutation lanes produce (`V2-02` §3.3). A disabled
        // lane maps to `nil`; its dormant stored value is never read as a
        // policy (§3.3).
        let policies = try RetentionConfigLoading.loadValidatedPolicies(
            in: context
        )

        return HistoryRetentionConfiguration(
            maximumUnpinnedItems: currentPolicy.maximumUnpinnedItems,
            policies: policies
        )
    }
}
