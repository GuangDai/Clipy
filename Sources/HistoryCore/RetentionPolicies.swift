/// RetentionPolicies.swift — the V2-02 public retention-policy values: the
/// three expansion dimensions (R1 age / R2 storage bytes / R3 revision
/// thresholds) as one optional-per-dimension policy value, plus the
/// authoritative configured-policy READ value (`HistoryRetentionConfiguration`)
/// the settings surface renders on panel-open.
/// Owning spec: docs/v2/V2-02-retention.md §3.1 (declaration shape and the
/// construction-time both-nil revision normalization); roadmap slice:
/// docs/v2/V2-roadmap.md §6 R.1 "Core contract" (RET-COMPILE-1/2); decision
/// record: DC-23 — all three dimensions ship as ONE policy value, each
/// independently disable-able via `nil` (`V2-roadmap` §4 DC-23). Distinct
/// from v1's package `RetentionPolicy` (`02` §5.5), which keeps the
/// untouched count dimension on `HistoryAction.setRetentionPolicy`
/// (`V2-02` §1). Foundation-only; immutable value semantics.
import Foundation

/// The three V2 retention dimensions in one policy value, each optional —
/// `nil` disables that dimension (DC-23). The v1 count dimension
/// (`maximumUnpinnedItems`) is deliberately absent: it stays on v1
/// `RetentionPolicy` / `.setRetentionPolicy`, so a v1 caller that ignores
/// this type behaves exactly as on v1 (`V2-00` §2.1; `V2-02` §3.1).
public struct HistoryRetentionPolicies: Sendable, Hashable {
    /// R1 — age-based item retention; `nil` = no age policy.
    public let age: AgeRetention?

    /// R2 — total-storage-byte item retention; `nil` = no byte policy.
    public let storage: StorageRetention?

    /// R3 — automatic revision retention; `nil` = no revision policy.
    public let revisions: RevisionRetention?

    public init(
        age: AgeRetention?,
        storage: StorageRetention?,
        revisions: RevisionRetention?
    ) {
        self.age = age
        self.storage = storage
        // Construction-time normalization (§3.1 prose): a `RevisionRetention`
        // with both thresholds nil is R3-disabled, so it is collapsed to nil
        // before storage - the public value never carries an "enabled but
        // no-op" R3 state at construction.
        self.revisions = (revisions?.maxRevisionsPerItem == nil
            && revisions?.maxRevisionBytesPerItem == nil) ? nil : revisions
    }
}

/// R1 — the age dimension (`V2-02` §2.1): items whose `lastCopiedAt` is older
/// than (commit reference time − `maxAge`) are retired, oldest-first, in the
/// same History Commit that admits them.
public struct AgeRetention: Sendable, Hashable {
    /// Seconds; retire items older than (now - maxAge). Admitted only when
    /// finite and within `1 s ... 3,650 d` at the HistoryStorage boundary
    /// (`V2-02` §8.3; DC-21 — NaN and ±Infinity are rejected there).
    public let maxAge: TimeInterval

    public init(maxAge: TimeInterval) {
        self.maxAge = maxAge
    }
}

/// R2 — the total-storage-byte dimension (`V2-02` §2.1): when the projected
/// retained set exceeds `maxTotalBytes` (a content-byte measure — Canonical
/// representation bytes plus revision content bytes, §3.2), oldest eligible
/// unpinned items are retired until the budget is restored.
public struct StorageRetention: Sendable, Hashable {
    /// Retire oldest until retained bytes <= maxTotalBytes. Admitted only
    /// within `1 ... 5,000 × 384 MiB` at the HistoryStorage boundary
    /// (`V2-02` §8.3).
    public let maxTotalBytes: Int

    public init(maxTotalBytes: Int) {
        self.maxTotalBytes = maxTotalBytes
    }
}

/// R3 — the automatic revision-retention dimension (`V2-02` §2.1, §5): when a
/// revision append or a policy change pushes an item past a threshold, the
/// oldest inactive revisions are pruned in the same History Commit; the
/// active revision is never pruned (D3). Each threshold is independently
/// optional; a value with BOTH thresholds nil is R3-disabled and is
/// normalized away by `HistoryRetentionPolicies.init` (§3.1).
public struct RevisionRetention: Sendable, Hashable {
    /// Prune oldest inactive beyond N (nil = no count limit). Admitted only
    /// within `1 ... 100` at the HistoryStorage boundary (`V2-02` §8.3).
    public let maxRevisionsPerItem: Int?

    /// Prune oldest inactive until under M (nil = no byte limit). Admitted
    /// only within `1 ... 256 MiB` at the HistoryStorage boundary
    /// (`V2-02` §8.3).
    public let maxRevisionBytesPerItem: Int?

    public init(maxRevisionsPerItem: Int?, maxRevisionBytesPerItem: Int?) {
        self.maxRevisionsPerItem = maxRevisionsPerItem
        self.maxRevisionBytesPerItem = maxRevisionBytesPerItem
    }
}

/// The authoritative CONFIGURED retention state in one value: the v1 count
/// dimension plus the three V2-02 dimensions, exactly as persisted — the
/// settings surface's panel-open read (`ClipboardHistory
/// .retentionConfiguration()`).
///
/// Owning spec: docs/v2/V2-07-ux.md §5.2 ("the settings panel shows the
/// configured budget") and §6.3 (each settings section renders from the
/// capability's status value on panel-open — a one-shot read per §4.2.2);
/// audit: docs/reviews/2026-08-20-clipy-maccy-audit/02-spec-implementation.md
/// SPEC-IMPL-003. This is configured POLICY state only; current content
/// counts and bytes are returned separately by `ClipboardHistory.usage()`.
/// This value carries no usage field. Both
/// halves travel together because V2-07 §6.3 renders the count control and
/// the V2-02 dimensions as ONE unified "Retention" group — one read, one
/// serialized snapshot, no cross-read drift.
public struct HistoryRetentionConfiguration: Sendable, Hashable {
    /// The v1 count dimension (docs/03a-instruction-set.md §5
    /// `.setRetentionPolicy`; `V2-02` §1 — the count never moved onto the
    /// V2 policy value). Always inside `HistoryLimits.standard
    /// .userMaximumUnpinnedRange` (docs/06-cross-cutting.md §2; the durable
    /// singleton is validated fail-closed on every read, `05` §16).
    public let maximumUnpinnedItems: Int

    /// The V2-02 age/storage/revision dimensions, each `nil` when that
    /// dimension is disabled (DC-23; `V2-02` §3.1). Disabled dimensions
    /// carry no dormant value: the storage read maps a disabled lane to
    /// `nil` without exposing its stored placeholder (`V2-02` §3.3).
    public let policies: HistoryRetentionPolicies

    public init(
        maximumUnpinnedItems: Int,
        policies: HistoryRetentionPolicies
    ) {
        self.maximumUnpinnedItems = maximumUnpinnedItems
        self.policies = policies
    }
}
