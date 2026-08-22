/// V2-02 §8.3 boundary validation of the public `HistoryRetentionPolicies`
/// value (roadmap slice `V2-roadmap` §6 R.1, consumed by the R.6
/// `.setRetentionPolicies` commit): every admitted dimension is checked
/// against the §8.3 bounds — accept at exactly the bound, reject at
/// bound ± 1 / zero / negative where sensible, and DC-21 non-finite
/// `maxAge` (NaN, ±Infinity). The all-disabled value validates clean
/// (v1-faithful no-op posture: no V2 policy active, v1 behavior unchanged).
///
/// Expected values below are the `V2-02` §8.3 literals, not the
/// implementation constants: R1 `1 s ... 3,650 d` (3,650 × 86,400 s =
/// 315,360,000 s); R2 `1 ... 5,000 × 384 MiB` (5,000 × 384 × 1,048,576 =
/// 2,013,265,920,000 bytes); R3 count `1 ... 100`; R3 bytes
/// `1 ... 256 MiB` (268,435,456 bytes). Every rejection is the v1 failure
/// producer `.invalidInput(.invalidRetentionPolicy)` — V2-02 §8.3 adds no
/// new `InvalidInputReason`.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("Retention policy boundary validation (V2-02 §8.3)")
struct RetentionPolicyBoundaryTests {

    /// The single §8.3 rejection for every out-of-bound dimension.
    private let invalidPolicy = HistoryFailure.invalidInput(.invalidRetentionPolicy)

    /// One policies value; every dimension defaults to disabled (`nil`),
    /// and each test overrides exactly the dimension under proof.
    private func policies(
        age: AgeRetention? = nil,
        storage: StorageRetention? = nil,
        revisions: RevisionRetention? = nil
    ) -> HistoryRetentionPolicies {
        HistoryRetentionPolicies(
            age: age,
            storage: storage,
            revisions: revisions
        )
    }

    // MARK: - All-disabled posture (v1-faithful no-op)

    @Test func allDisabledPoliciesValidateClean() {
        #expect(RetentionPolicyBounds.validate(policies()) == nil)
    }

    @Test func collapsedBothNilRevisionsStayAdmissible() {
        // A both-nil `RevisionRetention` is collapsed to `nil` at
        // construction (`V2-02` §3.1), so the admitted value is simply the
        // all-disabled R3 posture — nothing reaches the boundary in an
        // "enabled but no-op" state.
        let collapsed = policies(
            revisions: RevisionRetention(
                maxRevisionsPerItem: nil,
                maxRevisionBytesPerItem: nil
            )
        )
        #expect(collapsed.revisions == nil)
        #expect(RetentionPolicyBounds.validate(collapsed) == nil)
    }

    // MARK: - R1 maxAge (1 s ... 3,650 d; V2-02 §8.3)

    @Test func ageAcceptsExactlyTheBounds() {
        #expect(
            RetentionPolicyBounds.validate(
                policies(age: AgeRetention(maxAge: 1))
            ) == nil
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(age: AgeRetention(maxAge: 315_360_000))
            ) == nil
        )
    }

    @Test func ageRejectsZeroNegativeSubSecondAndAboveTheBound() {
        #expect(
            RetentionPolicyBounds.validate(
                policies(age: AgeRetention(maxAge: 0))
            ) == invalidPolicy
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(age: AgeRetention(maxAge: -1))
            ) == invalidPolicy
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(age: AgeRetention(maxAge: 0.5))
            ) == invalidPolicy
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(age: AgeRetention(maxAge: 315_360_001))
            ) == invalidPolicy
        )
    }

    @Test func ageRejectsNaNAndBothInfinities() {
        // DC-21: `maxAge` is a Double — every comparison with NaN is false,
        // so out-of-range checks alone cannot catch it; the boundary
        // requires finiteness explicitly (`V2-02` §8.3).
        #expect(
            RetentionPolicyBounds.validate(
                policies(age: AgeRetention(maxAge: .nan))
            ) == invalidPolicy
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(age: AgeRetention(maxAge: .infinity))
            ) == invalidPolicy
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(age: AgeRetention(maxAge: -.infinity))
            ) == invalidPolicy
        )
    }

    // MARK: - R2 maxTotalBytes (1 ... 5,000 × 384 MiB; V2-02 §8.3)

    @Test func storageAcceptsExactlyTheBounds() {
        #expect(
            RetentionPolicyBounds.validate(
                policies(storage: StorageRetention(maxTotalBytes: 1))
            ) == nil
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(storage: StorageRetention(maxTotalBytes: 2_013_265_920_000))
            ) == nil
        )
    }

    @Test func storageRejectsZeroNegativeAndAboveTheBound() {
        #expect(
            RetentionPolicyBounds.validate(
                policies(storage: StorageRetention(maxTotalBytes: 0))
            ) == invalidPolicy
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(storage: StorageRetention(maxTotalBytes: -1))
            ) == invalidPolicy
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(storage: StorageRetention(maxTotalBytes: 2_013_265_920_001))
            ) == invalidPolicy
        )
    }

    // MARK: - R3 maxRevisionsPerItem (1 ... 100; V2-02 §8.3)

    @Test func revisionCountAcceptsExactlyTheBounds() {
        #expect(
            RetentionPolicyBounds.validate(
                policies(revisions: RevisionRetention(
                    maxRevisionsPerItem: 1,
                    maxRevisionBytesPerItem: nil
                ))
            ) == nil
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(revisions: RevisionRetention(
                    maxRevisionsPerItem: 100,
                    maxRevisionBytesPerItem: nil
                ))
            ) == nil
        )
    }

    @Test func revisionCountRejectsZeroNegativeAndAboveTheBound() {
        #expect(
            RetentionPolicyBounds.validate(
                policies(revisions: RevisionRetention(
                    maxRevisionsPerItem: 0,
                    maxRevisionBytesPerItem: nil
                ))
            ) == invalidPolicy
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(revisions: RevisionRetention(
                    maxRevisionsPerItem: -1,
                    maxRevisionBytesPerItem: nil
                ))
            ) == invalidPolicy
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(revisions: RevisionRetention(
                    maxRevisionsPerItem: 101,
                    maxRevisionBytesPerItem: nil
                ))
            ) == invalidPolicy
        )
    }

    // MARK: - R3 maxRevisionBytesPerItem (1 ... 256 MiB; V2-02 §8.3)

    @Test func revisionBytesAcceptsExactlyTheBounds() {
        #expect(
            RetentionPolicyBounds.validate(
                policies(revisions: RevisionRetention(
                    maxRevisionsPerItem: nil,
                    maxRevisionBytesPerItem: 1
                ))
            ) == nil
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(revisions: RevisionRetention(
                    maxRevisionsPerItem: nil,
                    maxRevisionBytesPerItem: 268_435_456
                ))
            ) == nil
        )
    }

    @Test func revisionBytesRejectsZeroNegativeAndAboveTheBound() {
        #expect(
            RetentionPolicyBounds.validate(
                policies(revisions: RevisionRetention(
                    maxRevisionsPerItem: nil,
                    maxRevisionBytesPerItem: 0
                ))
            ) == invalidPolicy
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(revisions: RevisionRetention(
                    maxRevisionsPerItem: nil,
                    maxRevisionBytesPerItem: -1
                ))
            ) == invalidPolicy
        )
        #expect(
            RetentionPolicyBounds.validate(
                policies(revisions: RevisionRetention(
                    maxRevisionsPerItem: nil,
                    maxRevisionBytesPerItem: 268_435_457
                ))
            ) == invalidPolicy
        )
    }

    // MARK: - Dimension independence (§8.3 checks each admitted dimension)

    @Test func oneInvalidDimensionRejectsTheWholeValue() {
        // A valid R3 count cannot carry an invalid R3 byte threshold past
        // the boundary — each present threshold is checked.
        #expect(
            RetentionPolicyBounds.validate(
                policies(revisions: RevisionRetention(
                    maxRevisionsPerItem: 50,
                    maxRevisionBytesPerItem: 0
                ))
            ) == invalidPolicy
        )
        // A valid R1 cannot carry an invalid R2 past the boundary.
        #expect(
            RetentionPolicyBounds.validate(
                policies(
                    age: AgeRetention(maxAge: 60),
                    storage: StorageRetention(maxTotalBytes: 0)
                )
            ) == invalidPolicy
        )
    }

    @Test func everyDimensionAtItsUpperBoundIsValidTogether() {
        #expect(
            RetentionPolicyBounds.validate(
                policies(
                    age: AgeRetention(maxAge: 315_360_000),
                    storage: StorageRetention(maxTotalBytes: 2_013_265_920_000),
                    revisions: RevisionRetention(
                        maxRevisionsPerItem: 100,
                        maxRevisionBytesPerItem: 268_435_456
                    )
                )
            ) == nil
        )
    }
}
