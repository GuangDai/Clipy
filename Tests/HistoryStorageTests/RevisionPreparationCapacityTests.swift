/// Revision preparation capacity tests (docs/05-authority-kernel.md §6.2;
/// docs/06-cross-cutting.md §2). Per-item limits reject the proposed append
/// before a candidate revision can reach Domain planning.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

private func oneRevisionLimits() -> HistoryLimits {
    HistoryLimits(
        maximumRepresentationsPerCaptureOrRevision: 32,
        maximumTypeIdentifierUTF8Bytes: 512,
        maximumRepresentationBytes: 64 * 1_048_576,
        maximumCaptureBytes: 128 * 1_048_576,
        maximumProposedRevisionBytes: 64 * 1_048_576,
        maximumRevisionsPerItem: 1,
        maximumTotalRevisionBytesPerItem: 256 * 1_048_576,
        hardMaximumRetainedItems: 5_000,
        userMaximumUnpinnedLowerBound: 1,
        userMaximumUnpinnedUpperBound: 5_000,
        defaultMaximumUnpinnedItems: 200,
        maximumSourceApplicationObservationUTF8Bytes: 1_024,
        maximumStoredTitleUTF8Bytes: 1_024,
        maximumStoredSearchBodyUTF8Bytes: 256 * 1_024,
        pageRowLimitLowerBound: 1,
        pageRowLimitUpperBound: 500,
        maximumSearchTermUTF8Bytes: 4_096,
        maximumRegexpPatternCharacters: 512,
        maximumFuzzyQueryCharacters: 64,
        maximumFuzzyTitleBodyPrefixCharacters: 5_000,
        maximumRegexpTitleBodyPrefixCharacters: 1_000,
        maximumBodySearchSnippetCharacters: 322,
        thumbnailDimensionLowerBound: 1,
        thumbnailDimensionUpperBound: 2_048,
        maximumEncodedThumbnailBytes: 16 * 1_048_576
    )!
}

@Test func revisionPreparationRejectsAppendAtRevisionCountCapacity() async throws {
    let typeIdentifier = "public.utf8-plain-text"
    let canonical = try CanonicalContent(representations: [
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: typeIdentifier,
                bytes: Data("canonical".utf8)
            ),
            fingerprint: ContentFingerprint(rawValue: 1)
        ),
    ])
    let existingRevisionID = RevisionID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    )
    let existingRevision = ContentRevision(
        id: existingRevisionID,
        createdAt: Date(timeIntervalSinceReferenceDate: 700_300_000),
        content: EffectiveContent(representations: [
            ContentRepresentation(
                typeIdentifier: typeIdentifier,
                bytes: Data("revision".utf8)
            ),
        ])
    )
    let itemID = HistoryItemID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    )
    let request = RevisionRequest(
        itemID: itemID,
        expected: .initial,
        intent: .revert(to: .canonical)
    )
    let snapshot = RevisionPreparationSnapshot(
        canonical: canonical,
        current: existingRevision.content,
        revisions: [RevisionRetentionSummary(id: existingRevisionID, byteCount: 8)],
        activeRevisionID: existingRevisionID,
        contentVersion: .initial,
        revertedContent: nil
    )
    let preparation = RevisionPreparationActor(limits: oneRevisionLimits())

    await #expect(throws: HistoryFailure.capacityExceeded(.revisionCount)) {
        try await preparation.prepare(request, from: snapshot)
    }
}

@Test func revisionPreparationUsesInjectedIdentityAndClock() async throws {
    let typeIdentifier = "public.utf8-plain-text"
    let canonical = try CanonicalContent(representations: [
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: typeIdentifier,
                bytes: Data("canonical".utf8)
            ),
            fingerprint: ContentFingerprint(rawValue: 1)
        ),
    ])
    let itemID = HistoryItemID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
    )
    let fixedRevisionID = RevisionID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
    )
    let fixedDate = Date(timeIntervalSinceReferenceDate: 700_300_100)
    let preparation = RevisionPreparationActor(
        makeRevisionID: { fixedRevisionID },
        now: { fixedDate }
    )
    let request = RevisionRequest(
        itemID: itemID,
        expected: .initial,
        intent: .revert(to: .canonical)
    )
    let snapshot = RevisionPreparationSnapshot(
        canonical: canonical,
        current: EffectiveContent(representations: canonical.representations.map(\.content)),
        revisions: [],
        activeRevisionID: nil,
        contentVersion: .initial,
        revertedContent: nil
    )

    let bundle = try await preparation.prepare(request, from: snapshot)

    #expect(bundle.domain.candidateRevisionID == fixedRevisionID)
    #expect(bundle.domain.createdAt == fixedDate)
}

/// Preparation can admit an append only because R3 will prune. If the user
/// disables R3 before phase two, the current hard bound still applies (V2-02
/// §4.3/§5.4), and rejection must leave both content and position unchanged.
@Test func disablingR3BetweenRevisionPhasesCannotBypassHardCapacity() async throws {
    let location = try HistoryStoreLocation(persistence: .temporary)
    let authority = try HistoryAuthority(storeLocation: location, limits: oneRevisionLimits())
    try await authority.performStartup(initialMaximumUnpinnedItems: 200)
    let type = "public.utf8-plain-text"
    let capture = try await IngestPreparationActor().prepare(ClipboardCapture(
        representations: [CapturedRepresentation(typeIdentifier: type, bytes: Data("canonical".utf8))],
        origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
        observedAt: Date(timeIntervalSinceReferenceDate: 700_300_200)
    ))
    _ = try await authority.commitCapture(capture)
    let preparation = RevisionPreparationActor(limits: oneRevisionLimits())
    let firstRequest = RevisionRequest(
        itemID: capture.domain.candidateID,
        expected: .initial,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(typeIdentifier: type, action: .replace(bytes: Data("revision".utf8))),
        ]))
    )
    let firstInputs = try await authority.revisionPreparationInputs(firstRequest)
    let firstBundle = try await preparation.prepare(firstRequest, from: firstInputs.snapshot)
    _ = try await authority.commitRevision(firstRequest, firstBundle)
    _ = try await authority.commitRetentionPolicies(HistoryRetentionPolicies(
        age: nil, storage: nil,
        revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
    ))

    let parkedRequest = RevisionRequest(
        itemID: capture.domain.candidateID,
        expected: ContentVersion(rawValue: 2),
        intent: .revert(to: .canonical)
    )
    let parkedInputs = try await authority.revisionPreparationInputs(parkedRequest)
    let parkedBundle = try await preparation.prepare(
        parkedRequest, from: parkedInputs.snapshot,
        retentionPolicies: parkedInputs.retentionPolicies
    )
    _ = try await authority.commitRetentionPolicies(HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil))
    let positionBefore = try await authority.currentPosition()

    await #expect(throws: HistoryFailure.capacityExceeded(.revisionCount)) {
        try await authority.commitRevision(parkedRequest, parkedBundle)
    }

    #expect(try await authority.currentPosition() == positionBefore)
    let after = try await authority.revisionPreparationInputs(parkedRequest)
    #expect(after.snapshot.contentVersion == parkedInputs.snapshot.contentVersion)
    #expect(after.snapshot.current == parkedInputs.snapshot.current)
    #expect(after.snapshot.revisions.map(\.id) == parkedInputs.snapshot.revisions.map(\.id))
    #expect(after.retentionPolicies == nil)
}
