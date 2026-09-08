/// Direct pure-planner proofs for capture invariants D1, D3, D7, D9–D11,
/// D13–D14, D16, and D18–D19 (docs/02-domain.md §9, §12, §14).
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

internal enum CapturePlannerTestError: Error {
    case expectedCommit
    case expectedCoalescedOutcome
}

internal func capturePlannerID(_ suffix: UInt8) -> HistoryItemID {
    HistoryItemID(rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, suffix
    )))
}

internal func capturePlannerRevisionID(_ suffix: UInt8) -> RevisionID {
    RevisionID(rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, suffix
    )))
}

internal func captureCanonical(
    _ values: [(typeIdentifier: String, bytes: String, fingerprint: UInt64)]
) throws -> CanonicalContent {
    let sorted = values.sorted { lhs, rhs in
        lhs.typeIdentifier.unicodeScalars.lexicographicallyPrecedes(
            rhs.typeIdentifier.unicodeScalars
        )
    }
    return try CanonicalContent(representations: sorted.map { value in
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: value.typeIdentifier,
                bytes: Data(value.bytes.utf8)
            ),
            fingerprint: ContentFingerprint(rawValue: value.fingerprint)
        )
    })
}

internal func captureItem(
    id: HistoryItemID,
    canonical: CanonicalContent,
    lastCopiedAt: TimeInterval,
    count: UInt64 = 1,
    lastSource: String? = "existing.source",
    revisions: [ContentRevision] = [],
    activeRevisionID: RevisionID? = nil,
    pinOrdinal: PinOrdinal? = nil
) -> HistoryItemState {
    HistoryItemState(
        id: id,
        contentVersion: .initial,
        canonical: canonical,
        revisions: revisions,
        activeRevisionID: activeRevisionID,
        occurrence: CopyOccurrence(
            firstCopiedAt: Date(timeIntervalSinceReferenceDate: 0),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: lastCopiedAt),
            count: count,
            firstSource: "first.source",
            lastSource: lastSource
        ),
        pinOrdinal: pinOrdinal
    )
}

internal func captureSummary(_ item: HistoryItemState) -> RetainedItemSummary {
    RetainedItemSummary(
        id: item.id,
        lastCopiedAt: item.occurrence.lastCopiedAt,
        pinOrdinal: item.pinOrdinal
    )
}

internal func preparedCapture(
    canonical: CanonicalContent,
    observedAt: TimeInterval,
    candidateID: HistoryItemID = capturePlannerID(250),
    hint: HistoryItemID? = nil,
    source: String? = "incoming.source"
) -> PreparedCapture {
    PreparedCapture(
        candidateID: candidateID,
        canonical: canonical,
        origin: CopyOrigin(
            lineageHint: hint,
            sourceApplication: source
        ),
        observedAt: Date(timeIntervalSinceReferenceDate: observedAt)
    )
}

internal func captureFacts(
    incoming: CanonicalContent,
    hintedItem: HistoryItemState? = nil,
    candidates: [HistoryItemState],
    retained: [HistoryItemState]? = nil,
    additionalSummaries: [RetainedItemSummary] = [],
    candidateID: HistoryItemID = capturePlannerID(250),
    maximumUnpinnedItems: Int? = 100
) throws -> IngestFacts {
    var confirmedMatch: CaptureMatch?
    if let hintedItem {
        confirmedMatch = confirmLineageCapture(
            incoming: incoming,
            effective: try effectiveContent(of: hintedItem),
            id: hintedItem.id,
            occurrence: hintedItem.occurrence,
            pinOrdinal: hintedItem.pinOrdinal
        )
    }
    if confirmedMatch == nil {
        var best: CanonicalCaptureMatch?
        for item in candidates {
            guard let match = confirmCanonicalCapture(
                incoming: incoming,
                existing: item.canonical,
                id: item.id,
                occurrence: item.occurrence,
                pinOrdinal: item.pinOrdinal
            ) else { continue }
            best = best.map { preferredCanonicalCaptureMatch($0, match) } ?? match
        }
        confirmedMatch = best?.value
    }
    let retainedItems = retained ?? candidates
    let summaries = retainedItems.map(captureSummary) + additionalSummaries
    let unpinned = summaries.filter { $0.pinOrdinal == nil }.sorted {
        if $0.lastCopiedAt != $1.lastCopiedAt { return $0.lastCopiedAt < $1.lastCopiedAt }
        return $0.id < $1.id
    }
    let count = try captureRetirementCount(
        confirmedMatch: confirmedMatch, retainedCount: summaries.count,
        unpinnedCount: unpinned.count,
        retention: RetentionPolicy(maximumUnpinnedItems: maximumUnpinnedItems)
    )
    let primaryID = confirmedMatch?.id ?? candidateID
    let victims = Array(unpinned.filter { $0.id != primaryID }.prefix(count))
    let prefix = victims.last.map { last in
        RetentionRetirementPrefix(
            through: RetentionEvictionKey(lastCopiedAt: last.lastCopiedAt, itemID: last.id),
            excludedItemID: primaryID, itemCount: victims.count,
            canonicalBytes: victims.reduce(0) { total, victim in
                // Summary-only fixtures represent one-byte Canonical items.
                total + (retainedItems.first { $0.id == victim.id }?.canonical.representations
                    .reduce(0) { $0 + $1.content.bytes.count } ?? 1)
            },
            revisionBytes: victims.reduce(0) { total, victim in
                total + (retainedItems.first { $0.id == victim.id }?.revisions.reduce(0) {
                    $0 + $1.content.representations.reduce(0) { $0 + $1.bytes.count }
                } ?? 0)
            }
        )
    }
    return IngestFacts(
        confirmedMatch: confirmedMatch,
        candidateIDExists: summaries.contains { $0.id == candidateID },
        retention: CaptureRetentionFacts(
            retainedCount: summaries.count,
            unpinnedCount: unpinned.count,
            retirementPrefix: prefix
        )
    )
}

internal func capturePlan(
    incoming: CanonicalContent,
    candidates: [HistoryItemState],
    observedAt: TimeInterval = 500
) throws -> MutationPlan {
    let result = try planCapture(
        preparedCapture(canonical: incoming, observedAt: observedAt),
        facts: captureFacts(incoming: incoming, candidates: candidates),
        retention: RetentionPolicy(maximumUnpinnedItems: 100)
    )
    guard case .commit(let plan) = result else {
        throw CapturePlannerTestError.expectedCommit
    }
    return plan
}

internal func coalescedWinner(
    incoming: CanonicalContent,
    candidates: [HistoryItemState]
) throws -> HistoryItemID {
    let plan = try capturePlan(incoming: incoming, candidates: candidates)
    guard case .coalesced(let winnerID) = plan.outcome else {
        throw CapturePlannerTestError.expectedCoalescedOutcome
    }
    return winnerID
}

@Test func canonicalContentRejectsNonAdjacentCanonicallyEquivalentTypes() {
    let decomposed = "e\u{301}"
    let precomposed = "\u{e9}"

    #expect(
        throws: CanonicalContentRejection.duplicateTypeIdentifier(precomposed)
    ) {
        try CanonicalContent(representations: [
            CanonicalRepresentation(
                content: ContentRepresentation(
                    typeIdentifier: decomposed,
                    bytes: Data([0x01])
                ),
                fingerprint: ContentFingerprint(rawValue: 1)
            ),
            CanonicalRepresentation(
                content: ContentRepresentation(
                    typeIdentifier: "f",
                    bytes: Data([0x02])
                ),
                fingerprint: ContentFingerprint(rawValue: 2)
            ),
            CanonicalRepresentation(
                content: ContentRepresentation(
                    typeIdentifier: precomposed,
                    bytes: Data([0x03])
                ),
                fingerprint: ContentFingerprint(rawValue: 3)
            ),
        ])
    }
}

@Test func canonicalContainmentRequiresEveryIncomingTypeAndBytePair() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let richExisting = try captureCanonical([
        ("public.html", "html", 2),
        ("public.utf8-plain-text", "text", 99),
    ])
    let sameSignatureDifferentBytes = try captureCanonical([
        ("public.utf8-plain-text", "different", 1),
    ])

    #expect(canonicalContains(existing: richExisting, incoming: incoming))
    #expect(!canonicalContains(existing: incoming, incoming: richExisting))
    #expect(!canonicalContains(
        existing: sameSignatureDifferentBytes,
        incoming: incoming
    ))

    // Swift String equality is canonically equivalent even when the stable
    // persisted scalar order differs. The unrelated `f` representation makes
    // a raw-scalar merge walk miss the later precomposed equivalent.
    let canonicallyEquivalentIncoming = try captureCanonical([
        ("e\u{301}", "same", 3),
    ])
    let canonicallyEquivalentExisting = try captureCanonical([
        ("f", "unrelated", 4),
        ("\u{e9}", "same", 5),
    ])
    #expect(canonicalContains(
        existing: canonicallyEquivalentExisting,
        incoming: canonicallyEquivalentIncoming
    ))
}

@Test func fingerprintCollisionWithoutEqualBytesInsertsInsteadOfCoalescing() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "incoming", 42),
    ])
    let colliding = try captureCanonical([
        ("public.utf8-plain-text", "different", 42),
    ])
    let existing = captureItem(
        id: capturePlannerID(1),
        canonical: colliding,
        lastCopiedAt: 100
    )
    let candidateID = capturePlannerID(200)
    let result = try planCapture(
        preparedCapture(
            canonical: incoming,
            observedAt: 200,
            candidateID: candidateID
        ),
        facts: captureFacts(incoming: incoming, candidates: [existing]),
        retention: RetentionPolicy(maximumUnpinnedItems: 10)
    )

    guard case .commit(let plan) = result,
          case .inserted(let insertedID) = plan.outcome,
          plan.mutations.count == 1,
          case .create(let created) = plan.mutations[0]
    else {
        Issue.record("A fingerprint-only collision did not produce one create plan")
        return
    }
    #expect(insertedID == candidateID)
    #expect(created.id == candidateID)
}

@Test func insertRejectsCandidateItemIDAlreadyInRetainedInventory() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "new bytes", 101),
    ])
    let occupiedID = capturePlannerID(201)
    let retained = captureItem(
        id: occupiedID,
        canonical: try captureCanonical([
            ("public.utf8-plain-text", "existing bytes", 202),
        ]),
        lastCopiedAt: 100
    )

    #expect(throws: DomainRejection.candidateItemIDCollision(occupiedID)) {
        try planCapture(
            preparedCapture(
                canonical: incoming,
                observedAt: 200,
                candidateID: occupiedID
            ),
            facts: captureFacts(
                incoming: incoming,
                candidates: [],
                retained: [retained],
                candidateID: occupiedID
            ),
            retention: RetentionPolicy(maximumUnpinnedItems: 10)
        )
    }
}

@Test func coalesceIgnoresUnusedCandidateItemIDCollision() throws {
    let canonical = try captureCanonical([
        ("public.utf8-plain-text", "same bytes", 301),
    ])
    let existing = captureItem(
        id: capturePlannerID(202),
        canonical: canonical,
        lastCopiedAt: 100
    )
    let occupiedCandidate = captureItem(
        id: capturePlannerID(203),
        canonical: try captureCanonical([
            ("public.utf8-plain-text", "unrelated bytes", 302),
        ]),
        lastCopiedAt: 50
    )
    let result = try planCapture(
        preparedCapture(
            canonical: canonical,
            observedAt: 200,
            candidateID: occupiedCandidate.id
        ),
        facts: captureFacts(
            incoming: canonical,
            candidates: [existing],
            retained: [existing, occupiedCandidate],
            candidateID: occupiedCandidate.id
        ),
        retention: RetentionPolicy(maximumUnpinnedItems: 10)
    )

    guard case .commit(let plan) = result,
          case .coalesced(let winnerID) = plan.outcome,
          plan.mutations.count == 1,
          case .recordCopy(let mutatedID, _) = plan.mutations[0]
    else {
        Issue.record("An unused colliding candidate changed coalesce behavior")
        return
    }
    #expect(winnerID == existing.id)
    #expect(mutatedID == existing.id)
}

@Test func insertionCarriesTheCompleteInitialOccurrencePayload() throws {
    let canonical = try captureCanonical([
        ("public.utf8-plain-text", "new item", 1),
    ])
    let candidateID = capturePlannerID(200)
    let observedAt = Date(timeIntervalSinceReferenceDate: 321)
    let result = try planCapture(
        PreparedCapture(
            candidateID: candidateID,
            canonical: canonical,
            origin: CopyOrigin(
                lineageHint: nil,
                sourceApplication: "incoming.source"
            ),
            observedAt: observedAt
        ),
        facts: captureFacts(incoming: canonical, candidates: [], retained: []),
        retention: RetentionPolicy(maximumUnpinnedItems: 1)
    )

    guard case .commit(let plan) = result,
          case .inserted(let insertedID) = plan.outcome,
          plan.mutations.count == 1,
          case .create(let created) = plan.mutations[0]
    else {
        Issue.record("A valid first capture did not produce one complete create mutation")
        return
    }
    #expect(insertedID == candidateID)
    #expect(created.id == candidateID)
    #expect(created.canonical == canonical)
    #expect(created.occurrence.firstCopiedAt == observedAt)
    #expect(created.occurrence.lastCopiedAt == observedAt)
    #expect(created.occurrence.count == 1)
    #expect(created.occurrence.firstSource == "incoming.source")
    #expect(created.occurrence.lastSource == "incoming.source")
}

@Test func byteEqualLineageHintWinsBeforeCanonicalCandidates() throws {
    let original = try captureCanonical([
        ("public.utf8-plain-text", "original", 1),
    ])
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "revised", 2),
    ])
    let activeRevisionID = capturePlannerRevisionID(1)
    let activeRevision = ContentRevision(
        id: activeRevisionID,
        createdAt: Date(timeIntervalSinceReferenceDate: 50),
        content: EffectiveContent(
            representations: incoming.representations.map(\.content)
        )
    )
    let hinted = captureItem(
        id: capturePlannerID(1),
        canonical: original,
        lastCopiedAt: 100,
        revisions: [activeRevision],
        activeRevisionID: activeRevisionID
    )
    let canonicalCandidate = captureItem(
        id: capturePlannerID(2),
        canonical: incoming,
        lastCopiedAt: 900
    )
    let result = try planCapture(
        preparedCapture(
            canonical: incoming,
            observedAt: 200,
            hint: hinted.id
        ),
        facts: captureFacts(
            incoming: incoming,
            hintedItem: hinted,
            candidates: [canonicalCandidate],
            retained: [hinted, canonicalCandidate]
        ),
        retention: RetentionPolicy(maximumUnpinnedItems: 10)
    )

    guard case .commit(let plan) = result,
          case .coalesced(let winnerID) = plan.outcome,
          plan.mutations.count == 1,
          case .recordCopy(let mutatedID, _) = plan.mutations[0]
    else {
        Issue.record("A byte-equal lineage hint did not produce a coalesce plan")
        return
    }
    #expect(winnerID == hinted.id)
    #expect(mutatedID == hinted.id)
    #expect(mutatedID != canonicalCandidate.id)
}

@Test func mismatchedLineageHintFallsThroughToByteConfirmedCandidates() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "incoming", 1),
    ])
    let hinted = captureItem(
        id: capturePlannerID(1),
        canonical: try captureCanonical([
            ("public.utf8-plain-text", "different", 2),
        ]),
        lastCopiedAt: 900
    )
    let confirmed = captureItem(
        id: capturePlannerID(2),
        canonical: incoming,
        lastCopiedAt: 100
    )
    let result = try planCapture(
        preparedCapture(
            canonical: incoming,
            observedAt: 200,
            hint: hinted.id
        ),
        facts: captureFacts(
            incoming: incoming,
            hintedItem: hinted,
            candidates: [confirmed],
            retained: [hinted, confirmed]
        ),
        retention: RetentionPolicy(maximumUnpinnedItems: 10)
    )

    guard case .commit(let plan) = result,
          case .coalesced(let winnerID) = plan.outcome,
          plan.mutations.count == 1,
          case .recordCopy(let mutatedID, _) = plan.mutations[0]
    else {
        Issue.record("A mismatched hint did not fall through to byte confirmation")
        return
    }
    #expect(winnerID == confirmed.id)
    #expect(mutatedID == confirmed.id)
    #expect(mutatedID != hinted.id)
}

@Test func effectiveContentRejectsMissingActiveRevisionBeforeHintConfirmation() throws {
    let canonical = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let revision = ContentRevision(
        id: capturePlannerRevisionID(1),
        createdAt: Date(timeIntervalSinceReferenceDate: 50),
        content: EffectiveContent(
            representations: canonical.representations.map(\.content)
        )
    )
    let corruptHint = captureItem(
        id: capturePlannerID(1),
        canonical: canonical,
        lastCopiedAt: 100,
        revisions: [revision],
        activeRevisionID: nil
    )

    #expect(throws: DomainRejection.corruptLineage) {
        try effectiveContent(of: corruptHint)
    }
}

@Test func exactCanonicalCandidateBeatsNewerSuperset() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let superset = try captureCanonical([
        ("public.html", "html", 2),
        ("public.utf8-plain-text", "text", 1),
    ])
    let exactItem = captureItem(
        id: capturePlannerID(2),
        canonical: incoming,
        lastCopiedAt: 100
    )
    let newerSuperset = captureItem(
        id: capturePlannerID(1),
        canonical: superset,
        lastCopiedAt: 900
    )

    #expect(
        try coalescedWinner(
            incoming: incoming,
            candidates: [newerSuperset, exactItem]
        ) == exactItem.id
    )
}

@Test func canonicalContainmentDoesNotAuthorizePartialLineageMatch() throws {
    let incoming = try captureCanonical([("public.utf8-plain-text", "text", 1)])
    let rich = try captureCanonical([
        ("public.html", "<p>text</p>", 2),
        ("public.utf8-plain-text", "text", 99),
    ])
    let item = captureItem(
        id: capturePlannerID(7), canonical: rich, lastCopiedAt: 100,
        count: 9, pinOrdinal: PinOrdinal(rawValue: 2)
    )
    let canonicalMatch = try #require(confirmCanonicalCapture(
        incoming: incoming, existing: rich, id: item.id,
        occurrence: item.occurrence, pinOrdinal: item.pinOrdinal
    ))
    #expect(canonicalMatch.extraRepresentationCount == 1)
    #expect(canonicalMatch.value.id == item.id)
    #expect(canonicalMatch.value.occurrence == item.occurrence)
    #expect(canonicalMatch.value.pinOrdinal == item.pinOrdinal)
    #expect(confirmLineageCapture(
        incoming: incoming,
        effective: EffectiveContent(representations: rich.representations.map(\.content)),
        id: item.id, occurrence: item.occurrence, pinOrdinal: item.pinOrdinal
    ) == nil)
}

@Test(arguments: [false, true])
func lineageConfirmationUsesRepresentationSetsAcrossUnicodeOrder(_ decomposedIncoming: Bool) throws {
    let incomingType = decomposedIncoming ? "e\u{301}" : "\u{e9}"
    let existingType = decomposedIncoming ? "\u{e9}" : "e\u{301}"
    let incoming = try captureCanonical([(incomingType, "accent", 1), ("f", "other", 2)])
    let existing = try captureCanonical([(existingType, "accent", 3), ("f", "other", 4)])
    let item = captureItem(
        id: capturePlannerID(7), canonical: existing, lastCopiedAt: 100,
        count: 9, pinOrdinal: PinOrdinal(rawValue: 2)
    )
    let match = try #require(confirmLineageCapture(
        incoming: incoming,
        effective: EffectiveContent(representations: existing.representations.map(\.content)),
        id: item.id, occurrence: item.occurrence, pinOrdinal: item.pinOrdinal
    ))
    #expect(match.id == item.id)
    #expect(match.occurrence == item.occurrence)
    #expect(match.pinOrdinal == item.pinOrdinal)
}
