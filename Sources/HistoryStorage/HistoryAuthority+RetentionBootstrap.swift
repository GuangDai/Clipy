/// V2-02 §3.3/§8.3; V2-09 §6: retention defaults join the one startup
/// transaction. Missing configuration in a used store is never repaired.
import Foundation
import HistoryCore

// MARK: - V2-02 §8.3 policy bounds (package-internal single owner)

/// The `V2-02` §8.3 retention-policy bounds, enforced at every boundary that
/// accepts or validates persisted policies. These are the package-internal
/// constants for configured thresholds. Per-item resource bounds remain
/// separate from the optional overall count policy (V2-09 §9).
internal enum RetentionPolicyBounds {
    /// R1 `maxAge`: `1 s <= maxAge <= 3,650 d` (10 years; a practical upper
    /// bound — a value above it is a misconfigured sentinel, not an
    /// "enabled but never fires" state; `agePolicyEnabled` already gates
    /// firing). 3,650 d × 86,400 s/d = 315,360,000 s. (`V2-02` §8.3)
    internal static let ageSeconds: ClosedRange<TimeInterval> = 1 ... 3_650 * 86_400

    /// R2 accepts configured budgets up to 2,013,265,920,000 bytes
    /// (V2-02 §8.3). This is an independent policy-input upper bound, not
    /// a maximum store size or retained-item count; R2 may be disabled.
    internal static let totalBytes: ClosedRange<Int> = 1 ... 2_013_265_920_000

    /// R3 `maxRevisionsPerItem`: `1 <= maxRevisionsPerItem <= 100` — the
    /// active revision must survive (`>= 1`); `<= 100` is the `06` §2 hard
    /// bound. (`V2-02` §8.3)
    internal static let revisionsPerItem: ClosedRange<Int> = 1 ... 100

    /// R3 `maxRevisionBytesPerItem`: `1 <= maxRevisionBytesPerItem <=
    /// 256 MiB` — the `06` §2 per-item-revision-byte hard bound; an R3
    /// threshold above the hard bound is meaningless because the hard bound
    /// already rejects. 256 × 1,048,576 = 268,435,456 bytes. (`V2-02` §8.3)
    internal static let revisionBytesPerItem: ClosedRange<Int> = 1 ... 256 * 1_048_576

    /// Boundary validation of one public `HistoryRetentionPolicies` value
    /// against the §8.3 bounds above — the seam the R.6
    /// `.setRetentionPolicies` commit consumes
    /// (`V2-roadmap` §6 R.6; `V2-02` §8.3 "An out-of-range / inconsistent
    /// `HistoryRetentionPolicies` → `.invalidInput(.invalidRetentionPolicy)`
    /// at the `HistoryStorage` boundary"). Every ADMITTED dimension is
    /// checked (nil dimensions are disabled and skip their bound); `nil`
    /// means the value is admittable.
    ///
    /// Returns (rather than throws) because this is a pure predicate over an
    /// immutable value — no store access, so there is nothing to interrupt;
    /// the throwing style in this file is reserved for the store-touching
    /// bootstrap. The rejection reuses the v1 failure producer with no new
    /// `InvalidInputReason` (`V2-02` §8.3).
    ///
    /// Whole-value consistency beyond the bounds is NOT re-checked here:
    /// the both-nil `RevisionRetention` normalization is construction-time
    /// on the public initializer (`V2-02` §3.1), so an "enabled but no-op"
    /// R3 state cannot reach this boundary through that initializer — the
    /// defensive re-check below exists only so a future construction path
    /// cannot silently reintroduce the state.
    internal static func validate(
        _ policies: HistoryRetentionPolicies
    ) -> HistoryFailure? {
        if let age = policies.age {
            // DC-21: `maxAge` is a `Double` — every comparison with NaN is
            // false, so the range check alone cannot catch it; the boundary
            // requires finiteness explicitly. ±.infinity also fails the
            // range, but the explicit gate keeps the rejection structural
            // rather than incidental. (`V2-02` §8.3)
            guard age.maxAge.isFinite,
                  ageSeconds.contains(age.maxAge)
            else {
                return .invalidInput(.invalidRetentionPolicy)
            }
        }
        if let storage = policies.storage {
            guard totalBytes.contains(storage.maxTotalBytes) else {
                return .invalidInput(.invalidRetentionPolicy)
            }
        }
        if let revisions = policies.revisions {
            // Defensive (§3.1 normalization is construction-time): an
            // all-nil `RevisionRetention` cannot arrive here through the
            // public initializer, but this branch keeps such a value from
            // ever being admitted as "enabled" should another construction
            // path appear.
            guard revisions.maxRevisionsPerItem != nil
                || revisions.maxRevisionBytesPerItem != nil
            else {
                return .invalidInput(.invalidRetentionPolicy)
            }
            if let maxRevisions = revisions.maxRevisionsPerItem {
                guard revisionsPerItem.contains(maxRevisions) else {
                    return .invalidInput(.invalidRetentionPolicy)
                }
            }
            if let maxRevisionBytes = revisions.maxRevisionBytesPerItem {
                guard revisionBytesPerItem.contains(maxRevisionBytes) else {
                    return .invalidInput(.invalidRetentionPolicy)
                }
            }
        }
        return nil
    }
}

extension HistoryAuthority {
    internal static let retentionExpansionConfigKey = "retention-expansion"

    /// The caller owns the startup write transaction. Present policies use
    /// the same validator as capture, revise, and the Settings read.
    internal static func ensureRetentionExpansionConfig(
        in database: SQLiteDatabase
    ) throws {
        do {
            let config = try database.prepare(
                "SELECT key FROM retention_policies LIMIT 2"
            )
            defer { config.finalize() }
            if try config.step() {
                guard try config.text(at: 0) == retentionExpansionConfigKey,
                      try !config.step() else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                _ = try RetentionConfigLoading.loadValidatedPolicies(in: database)
                return
            }

            let state = try database.prepare("""
                SELECT key, changePosition, retainedItemCount,
                    EXISTS(SELECT 1 FROM history_items LIMIT 1)
                FROM history_state LIMIT 2
                """)
            defer { state.finalize() }
            guard try state.step(),
                  try state.text(at: 0) == positionSingletonKey,
                  try sqliteUInt64(state.blob(at: 1)) == 0,
                  try state.integer(at: 2) == 0,
                  try state.integer(at: 3) == 0,
                  try !state.step() else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            try database.execute("""
                INSERT INTO retention_policies
                    (key, ageMaxSeconds, storageMaxBytes,
                     revisionMaxCount, revisionMaxBytes)
                VALUES (?, NULL, NULL, NULL, NULL)
                """, bindings: [.text(retentionExpansionConfigKey)])
        } catch let failure as HistoryFailure {
            throw failure
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
    }
}
