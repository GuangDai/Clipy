/// M1.3 — the retention-expansion config bootstrap: load-or-create exactly
/// one `RetentionExpansionConfigRow` and validate it fail-closed.
/// Owning spec: `V2-02` §3.3 (`RetentionExpansionConfigRow` singleton,
/// `configSchemaVersion` contract) and §8.3 (the policy bounds); open order:
/// `V2-roadmap` §5 M1 total open order step 5 (immediately after the v1
/// position singleton steps 3–4, before the retained-row scan); DC-21
/// (persisted non-finite `ageMaxSeconds` never silently reads as
/// disabled/infinite).
///
/// The shape mirrors `ensurePositionSingleton` (v1 `05` §13 steps 3–4):
/// the create is one `ModelContext.transaction` whose success is the durable
/// boundary, a store that cannot be read or written fails as
/// `.persistence(.openStore)` (§2's startup vocabulary), and zero-duplicate
/// cardinality violations are `.persistence(.invariantViolation)`. Migration
/// never creates this row (`V2-02` §3.3 Stage topology / Record 5: data
/// bootstrap is `open`, not migration) — an absent row is the only
/// create-with-defaults path.
import Foundation
import HistoryCore
import SwiftData

// MARK: - V2-02 §8.3 policy bounds (package-internal single owner)

/// The `V2-02` §8.3 retention-policy bounds, enforced at every boundary that
/// accepts or validates persisted policies. These are the package-internal
/// constants the config validation below uses; user thresholds are always at
/// or below the `06` §2 hard bounds the ranges are derived from.
internal enum RetentionPolicyBounds {
    /// R1 `maxAge`: `1 s <= maxAge <= 3,650 d` (10 years; a practical upper
    /// bound — a value above it is a misconfigured sentinel, not an
    /// "enabled but never fires" state; `agePolicyEnabled` already gates
    /// firing). 3,650 d × 86,400 s/d = 315,360,000 s. (`V2-02` §8.3)
    internal static let ageSeconds: ClosedRange<TimeInterval> = 1 ... 3_650 * 86_400

    /// R2 `maxTotalBytes`: `1 <= maxTotalBytes <= 5,000 × 384 MiB` — the
    /// worst-case store footprint: 5,000 items × (≤128 MiB Canonical +
    /// 256 MiB revisions) (`06` §2); a budget above the worst case is
    /// meaningless. 5,000 × 384 × 1,048,576 = 2,013,265,920,000 bytes.
    /// (`V2-02` §8.3)
    internal static let totalBytes: ClosedRange<Int> = 1 ... 5_000 * 384 * 1_048_576

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
    /// `.setRetentionPolicies` commit consumes when it lands
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

// MARK: - Config bootstrap (V2-roadmap §5 total open order step 5)

extension HistoryAuthority {

    /// The config singleton's well-known key (`V2-02` §3.3: always
    /// "retention-expansion").
    internal static let retentionExpansionConfigKey = "retention-expansion"

    /// The only config schema version this reader understands (`V2-02` §3.3;
    /// the codec discipline of a blob `formatVersion`, `05` §4).
    internal static let retentionConfigSchemaVersion: UInt16 = 1

    /// Bootstraps/validates the retention-expansion config singleton
    /// (`V2-roadmap` §5 total open order step 5, M1.3).
    ///
    /// Per `V2-02` §3.3: "A migrated v1 store has no
    /// `RetentionExpansionConfigRow`; `SwiftDataHistory.open` creates it with
    /// all policies disabled ... so a migrated store starts v1-faithful" —
    /// an absent row is the only create-with-defaults path, never a version
    /// mismatch. A present row is validated as one unit and fails closed:
    ///
    /// - `configSchemaVersion != 1` → `.persistence(.corruptStoredValue)`
    ///   (forward-incompatible; the codec-discipline analog of an unknown
    ///   blob `formatVersion`, `05` §4);
    /// - a non-finite `ageMaxSeconds` → `.persistence(.corruptStoredValue)`
    ///   (DC-21: out-of-range comparisons cannot catch `NaN`, and a persisted
    ///   non-finite age never silently reads as disabled/infinite);
    /// - an out-of-range or contradictory combination →
    ///   `.persistence(.invariantViolation)`, using the `V2-02` §8.3 bounds:
    ///   `agePolicyEnabled` with an out-of-range `ageMaxSeconds`;
    ///   `storagePolicyEnabled` with an out-of-range `storageMaxBytes`;
    ///   `revisionPolicyEnabled` with BOTH thresholds nil (the named
    ///   contradiction); any non-nil threshold outside its range.
    ///
    /// Cardinality mirrors the v1 singleton (`05` §13 step 4): duplicate
    /// rows are `.persistence(.invariantViolation)`. A store that cannot be
    /// read or written fails as `.persistence(.openStore)` — §2's startup
    /// failure vocabulary, which does not include `.transaction`.
    internal static func ensureRetentionExpansionConfig(
        in context: ModelContext
    ) throws {
        let key = retentionExpansionConfigKey
        var descriptor = FetchDescriptor<RetentionExpansionConfigRow>(
            predicate: #Predicate { row in row.key == key }
        )
        descriptor.fetchLimit = 2
        let rows: [RetentionExpansionConfigRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        switch rows.count {
        case 0:
            // `V2-02` §3.3 / `V2-roadmap` §5 step 5: created at open, all
            // policies disabled (`configSchemaVersion == 1`), so a migrated
            // store starts v1-faithful. One `ModelContext.transaction`,
            // exactly like the v1 singleton create (§10: closure success is
            // the durable boundary; no `save()` follows it).
            do {
                try context.transaction {
                    context.insert(RetentionExpansionConfigRow(
                        key: key,
                        agePolicyEnabled: false,
                        ageMaxSeconds: 0,
                        storagePolicyEnabled: false,
                        storageMaxBytes: 0,
                        revisionPolicyEnabled: false,
                        revisionMaxCount: nil,
                        revisionMaxBytes: nil,
                        configSchemaVersion: retentionConfigSchemaVersion
                    ))
                }
            } catch {
                throw HistoryFailure.persistence(.openStore)
            }
        case 1:
            try validateRetentionExpansionConfig(rows[0])
        default:
            // Duplicate singletons (05 §13 step 4 vocabulary): corruption,
            // never a choose-one repair.
            throw HistoryFailure.persistence(.invariantViolation)
        }
    }

    /// The fail-closed unit validation of one already-stored config row
    /// (`V2-02` §3.3 "configSchemaVersion contract"). Order is fixed:
    /// version fence, then DC-21 finiteness, then the §8.3
    /// range/contradiction checks — so a row violating several contracts
    /// reports the first in this order.
    private static func validateRetentionExpansionConfig(
        _ row: RetentionExpansionConfigRow
    ) throws {
        // The version fence (05 §4 codec discipline): an unknown version is
        // forward-incompatible and is never read as a possibly-different
        // policy set.
        guard row.configSchemaVersion == retentionConfigSchemaVersion else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        // DC-21: a persisted non-finite ageMaxSeconds never silently reads
        // as disabled (comparison guards alone cannot catch NaN).
        guard row.ageMaxSeconds.isFinite else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        // V2-02 §8.3 bounds gate every ENABLED policy value and every
        // non-nil R3 threshold; a disabled policy's dormant value is not
        // range-checked (the all-disabled default itself carries 0s).
        if row.agePolicyEnabled {
            guard RetentionPolicyBounds.ageSeconds.contains(row.ageMaxSeconds) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
        }
        if row.storagePolicyEnabled {
            guard RetentionPolicyBounds.totalBytes.contains(row.storageMaxBytes) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
        }
        if row.revisionPolicyEnabled {
            // The named contradiction (§3.3): enabled with no threshold in
            // either dimension is incoherent, not a no-op.
            guard row.revisionMaxCount != nil || row.revisionMaxBytes != nil else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
        }
        if let revisionMaxCount = row.revisionMaxCount {
            guard RetentionPolicyBounds.revisionsPerItem.contains(revisionMaxCount) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
        }
        if let revisionMaxBytes = row.revisionMaxBytes {
            guard RetentionPolicyBounds.revisionBytesPerItem.contains(revisionMaxBytes) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
        }
    }
}
