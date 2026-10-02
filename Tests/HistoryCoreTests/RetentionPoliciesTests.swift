/// Public revision-threshold normalization and independent optional dimensions.
import HistoryCore
import Testing

@Test(arguments: [
    (RevisionRetention(maxRevisionsPerItem: nil, maxRevisionBytesPerItem: nil), Optional<RevisionRetention>.none),
    (RevisionRetention(maxRevisionsPerItem: 10, maxRevisionBytesPerItem: nil),
        RevisionRetention(maxRevisionsPerItem: 10, maxRevisionBytesPerItem: nil)),
    (RevisionRetention(maxRevisionsPerItem: nil, maxRevisionBytesPerItem: 134_217_728),
        RevisionRetention(maxRevisionsPerItem: nil, maxRevisionBytesPerItem: 134_217_728)),
    (RevisionRetention(maxRevisionsPerItem: 100, maxRevisionBytesPerItem: 268_435_456),
        RevisionRetention(maxRevisionsPerItem: 100, maxRevisionBytesPerItem: 268_435_456)),
])
func retentionPoliciesNormalizeOnlyEmptyRevisionThresholds(
    input: RevisionRetention, expected: RevisionRetention?
) {
    let policies = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 60), storage: nil, revisions: input
    )
    #expect(policies.revisions == expected)
    #expect(policies.age?.maxAge == 60)
    #expect(policies.storage == nil)
}

@Test func retentionPoliciesCarryEachDimensionIndependently() {
    let ageOnly = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 3_600), storage: nil, revisions: nil
    )
    #expect(ageOnly.age?.maxAge == 3_600)
    #expect(ageOnly.storage == nil)
    #expect(ageOnly.revisions == nil)

    let storageOnly = HistoryRetentionPolicies(
        age: nil, storage: StorageRetention(maxTotalBytes: 1_048_576), revisions: nil
    )
    #expect(storageOnly.age == nil)
    #expect(storageOnly.storage?.maxTotalBytes == 1_048_576)
    #expect(storageOnly.revisions == nil)
}
