/// Public revision-threshold normalization.
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
}
