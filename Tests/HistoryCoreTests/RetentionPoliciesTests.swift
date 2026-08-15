/// V2-02 §3.1 public policy values (roadmap slice `V2-roadmap` §6 R.1,
/// `RET-COMPILE-1`): the construction-time both-nil revision normalization,
/// per-dimension optionality, value equality/hashing, and Sendable usage.
/// Expected behavior is taken from `V2-02` §3.1's declarations and prose,
/// not from the implementation. Everything exercised here is the public
/// caller surface — a plain `import HistoryCore`, no `@testable`.
import Foundation
import HistoryCore
import Testing

// MARK: - Construction-time revision normalization (V2-02 §3.1)

@Test func retentionPoliciesCollapseBothNilRevisionThresholdsToNil() {
    let policies = HistoryRetentionPolicies(
        age: nil,
        storage: nil,
        revisions: RevisionRetention(
            maxRevisionsPerItem: nil,
            maxRevisionBytesPerItem: nil
        )
    )
    // "A `RevisionRetention` with both thresholds `nil` is normalized to
    // `revisions == nil` ... at `HistoryRetentionPolicies.init` construction"
    // — the public value never carries an "enabled but no-op" R3 state
    // (`V2-02` §3.1), not merely at the `.setRetentionPolicies` boundary.
    #expect(policies.revisions == nil)
    #expect(policies.age == nil)
    #expect(policies.storage == nil)
}

@Test func retentionPoliciesKeepCountThresholdAlone() {
    let policies = HistoryRetentionPolicies(
        age: nil,
        storage: nil,
        revisions: RevisionRetention(
            maxRevisionsPerItem: 10,
            maxRevisionBytesPerItem: nil
        )
    )
    #expect(policies.revisions?.maxRevisionsPerItem == 10)
    #expect(policies.revisions?.maxRevisionBytesPerItem == nil)
}

@Test func retentionPoliciesKeepByteThresholdAlone() {
    let policies = HistoryRetentionPolicies(
        age: nil,
        storage: nil,
        revisions: RevisionRetention(
            maxRevisionsPerItem: nil,
            maxRevisionBytesPerItem: 134_217_728
        )
    )
    #expect(policies.revisions?.maxRevisionsPerItem == nil)
    #expect(policies.revisions?.maxRevisionBytesPerItem == 134_217_728)
}

@Test func retentionPoliciesKeepBothRevisionThresholds() {
    let policies = HistoryRetentionPolicies(
        age: nil,
        storage: nil,
        revisions: RevisionRetention(
            maxRevisionsPerItem: 100,
            maxRevisionBytesPerItem: 268_435_456
        )
    )
    #expect(policies.revisions?.maxRevisionsPerItem == 100)
    #expect(policies.revisions?.maxRevisionBytesPerItem == 268_435_456)
}

// MARK: - Per-dimension optionality (each nil = disabled, DC-23)

@Test func retentionPoliciesCarryEachDimensionIndependently() {
    let ageOnly = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 3_600),
        storage: nil,
        revisions: nil
    )
    #expect(ageOnly.age?.maxAge == 3_600)
    #expect(ageOnly.storage == nil)
    #expect(ageOnly.revisions == nil)

    let storageOnly = HistoryRetentionPolicies(
        age: nil,
        storage: StorageRetention(maxTotalBytes: 1_048_576),
        revisions: nil
    )
    #expect(storageOnly.age == nil)
    #expect(storageOnly.storage?.maxTotalBytes == 1_048_576)
    #expect(storageOnly.revisions == nil)
}

// MARK: - Equality and hashing (Hashable)

@Test func retentionPoliciesNormalizeToEqualValues() {
    // The collapsed both-nil revision policy and an absent one are the same
    // value: normalization is construction-time (`V2-02` §3.1), so equality
    // cannot distinguish them.
    let collapsed = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 60),
        storage: nil,
        revisions: RevisionRetention(
            maxRevisionsPerItem: nil,
            maxRevisionBytesPerItem: nil
        )
    )
    let absent = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 60),
        storage: nil,
        revisions: nil
    )
    #expect(collapsed == absent)
    // Equal values must share one hash (the Hashable contract).
    #expect(collapsed.hashValue == absent.hashValue)
}

@Test func retentionPoliciesDifferWhenDimensionsDiffer() {
    let disabled = HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil)
    let ageOnly = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 1),
        storage: nil,
        revisions: nil
    )
    let storageOnly = HistoryRetentionPolicies(
        age: nil,
        storage: StorageRetention(maxTotalBytes: 1),
        revisions: nil
    )
    let revisionsOnly = HistoryRetentionPolicies(
        age: nil,
        storage: nil,
        revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
    )
    #expect(disabled != ageOnly)
    #expect(disabled != storageOnly)
    #expect(disabled != revisionsOnly)
    #expect(ageOnly != storageOnly)
}

@Test func retentionPolicyDimensionsCompareByFieldValue() {
    #expect(AgeRetention(maxAge: 1) == AgeRetention(maxAge: 1))
    #expect(AgeRetention(maxAge: 1) != AgeRetention(maxAge: 2))
    #expect(StorageRetention(maxTotalBytes: 1) == StorageRetention(maxTotalBytes: 1))
    #expect(StorageRetention(maxTotalBytes: 1) != StorageRetention(maxTotalBytes: 2))
    #expect(
        RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
            == RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
    )
    #expect(
        RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
            != RevisionRetention(maxRevisionsPerItem: nil, maxRevisionBytesPerItem: 1)
    )
}

@Test func retentionPoliciesDeduplicateInASet() {
    var set: Set<HistoryRetentionPolicies> = []
    set.insert(HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil))
    set.insert(HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil))
    set.insert(
        HistoryRetentionPolicies(
            age: nil,
            storage: nil,
            revisions: RevisionRetention(
                maxRevisionsPerItem: nil,
                maxRevisionBytesPerItem: nil
            )
        )
    )
    // Two spellings of one value (absent and collapsed both-nil revisions)
    // occupy one Set slot.
    #expect(set.count == 1)
}

// MARK: - Sendable

@Test func retentionPolicyValuesCrossSendableBoundaries() {
    let policies = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 3_600),
        storage: StorageRetention(maxTotalBytes: 1_048_576),
        revisions: RevisionRetention(
            maxRevisionsPerItem: 5,
            maxRevisionBytesPerItem: 1_048_576
        )
    )
    // A `@Sendable` closure accepting the value types compiles only when the
    // types are Sendable — under complete strict concurrency the compile
    // itself is the assertion that these are immutable `Sendable` values.
    let reads: @Sendable (HistoryRetentionPolicies) -> Bool = { value in
        value.age?.maxAge == 3_600
            && value.storage?.maxTotalBytes == 1_048_576
            && value.revisions?.maxRevisionsPerItem == 5
            && value.revisions?.maxRevisionBytesPerItem == 1_048_576
    }
    #expect(reads(policies))
}
