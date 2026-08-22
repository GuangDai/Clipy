/// WS9 — Retention in the primary commit (docs/06-cross-cutting.md §8 WS9):
/// with the user retention policy at maximum unpinned 2, inserting a third
/// unpinned item retires the oldest eligible unpinned item INSIDE the third
/// insert's own History Commit — an insert and its retention victims are one
/// commit (docs/02-domain.md §12), so Change Position advances exactly once
/// for the combined plan (docs/02-domain.md §13, D6) — plus the hard-bound
/// capacity failure proved at the Domain planner seam.
///
/// Phasing (docs/roadmap/README.md §3, WS-clause phasing note): WS9's
/// public-read clause (the retained set as reported by the step-7 `browse`
/// read) defers to step 7; this file closes the step-6 commit/receipt/storage
/// clauses — the `.inserted` receipts at Change Positions 1–3, the
/// once-per-commit position advance, the retired ID's absence, and the two
/// surviving unpinned rows as seen through an INDEPENDENT second
/// `ModelContainer` over the same on-disk store (see `WSSupport`).
///
/// PLANNER-SEAM CAPACITY PROOF (06 §8 WS9's own note): the fixed 5,000-item
/// `HistoryLimits.standard` hard retained-item bound makes a full end-to-end
/// all-pinned-at-hard-bound store impractical to construct, so the
/// `.capacityExceeded(.retainedItems)` path is proved at the Domain planner
/// seam, where the bound is a parameter — `planCapture` with
/// `hardMaximumRetainedItems` equal to the current retained count and every
/// retained item pinned must throw rather than retire a pinned item (D13) or
/// the primary itself (docs/02-domain.md §12, D19).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS9RetentionPrimaryCommitTests {

/// WS9 (docs/06-cross-cutting.md §8): with maximum unpinned 2, three distinct
/// unpinned captures commit at positions 1, 2, 3; the third commit retires
/// the oldest item in the SAME History Commit, leaving exactly items two and
/// three (both unpinned, untouched), item one's ID absent, and the position
/// singleton at 3 — one advance per commit, never one per mutation.
@Test func thirdCaptureRetiresTheOldestUnpinnedItemInsideTheSameHistoryCommit() async throws {
    let storeURL = WSSupport.tempStoreURL("ws9-retention-primary-commit")
    defer { WSSupport.removeStore(storeURL) }
    // WS9: "Configure maximum unpinned count 2".
    let history = try await WSSupport.openHistory(storeURL: storeURL, maximumUnpinned: 2)

    // Three DISTINCT unpinned text captures with strictly increasing
    // observedAt: eviction order is `lastCopiedAt` ascending
    // (docs/02-domain.md §12), so item one is the oldest eligible victim
    // once the policy is exceeded.
    let firstText = "ws9 retention item one"
    let secondText = "ws9 retention item two"
    let thirdText = "ws9 retention item three"
    let firstObservedAt = Date(timeIntervalSinceReferenceDate: 700_030_000)
    let secondObservedAt = Date(timeIntervalSinceReferenceDate: 700_030_100)
    let thirdObservedAt = Date(timeIntervalSinceReferenceDate: 700_030_200)
    let source = "com.example.ws9"

    // Insert one on the empty store: `.inserted` at Change Position 1.
    let firstReceipt = try await history.perform(.capture(
        WSSupport.textCapture(firstText, observedAt: firstObservedAt, source: source)
    ))
    guard case let .committed(firstCommit) = firstReceipt,
          case let .inserted(firstReference) = firstCommit.outcome
    else {
        Issue.record("WS9: expected .committed(.inserted) for capture one, got \(firstReceipt)")
        return
    }
    // WS9: the first insert moves the singleton 0 → 1.
    #expect(firstCommit.position.rawValue == 1)
    #expect(!firstCommit.hasDestructiveRetentionEffects)

    // Insert two: `.inserted` at position 2 — two unpinned items still
    // satisfy the policy, so nothing retires yet.
    let secondReceipt = try await history.perform(.capture(
        WSSupport.textCapture(secondText, observedAt: secondObservedAt, source: source)
    ))
    guard case let .committed(secondCommit) = secondReceipt,
          case let .inserted(secondReference) = secondCommit.outcome
    else {
        Issue.record("WS9: expected .committed(.inserted) for capture two, got \(secondReceipt)")
        return
    }
    #expect(secondCommit.position.rawValue == 2)
    #expect(!secondCommit.hasDestructiveRetentionEffects)

    // WS9: the SECOND commit carried no victim — the policy (2 unpinned) is
    // exactly satisfied, so both rows and the position singleton at 2 are
    // durable before the third capture (the retirement below belongs to the
    // third commit, not to an earlier one).
    let midway = try WSSupport.makeContainer(storeURL: storeURL)
    #expect(try WSSupport.fetchRows(midway).count == 2)
    #expect(try WSSupport.fetchPosition(midway).rawValue == 2)

    // Act: insert three pushes the unpinned count to 3 > 2.
    let thirdReceipt = try await history.perform(.capture(
        WSSupport.textCapture(thirdText, observedAt: thirdObservedAt, source: source)
    ))
    // WS9: the third capture is itself a History Commit with `.inserted` —
    // the primary is never its own retention victim (docs/02-domain.md §12).
    guard case let .committed(thirdCommit) = thirdReceipt,
          case let .inserted(thirdReference) = thirdCommit.outcome
    else {
        Issue.record("WS9: expected .committed(.inserted) for capture three, got \(thirdReceipt)")
        return
    }
    // WS9: "ChangePosition advanced once" — the create and the retention
    // retire are ONE plan, so the position moves 2 → 3 exactly once
    // (docs/02-domain.md §13: one advance per plan, not per mutation).
    #expect(thirdCommit.position.rawValue == 3)
    #expect(thirdCommit.hasDestructiveRetentionEffects)

    // Storage side, through the INDEPENDENT container.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    // WS9: "leaving two unpinned items" — the third commit retired exactly
    // one item.
    #expect(rows.count == 2)
    // WS9: "the retired ID is gone" — item one's ID is absent; items two and
    // three are the survivors.
    let retainedIDs = Set(rows.map(\.id))
    #expect(!retainedIDs.contains(firstReference.id.rawValue))
    #expect(retainedIDs == [secondReference.id.rawValue, thirdReference.id.rawValue])
    // The survivors are still unpinned and untouched by the retention
    // commit: initial Content Version, occurrence count 1, original bytes.
    let expectedTextByID: [UUID: String] = [
        secondReference.id.rawValue: secondText,
        thirdReference.id.rawValue: thirdText,
    ]
    for row in rows {
        #expect(row.pinOrdinal == nil)
        #expect(row.contentVersionRaw == 1)
        #expect(row.copyCount == 1)
        let expectedText = try #require(expectedTextByID[row.id])
        let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
        #expect(canonical.representations.map(\.content.bytes) == [Data(expectedText.utf8)])
    }

    // WS9: the durable singleton matches the third receipt — three commits
    // total, so the same-commit retirement added no extra advance.
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 3)
}

/// WS9 (docs/06-cross-cutting.md §8, planner seam): with
/// `hardMaximumRetainedItems` equal to the current retained count and EVERY
/// retained item pinned, capture planning throws
/// `.capacityExceeded(.retainedItems)` — pinned items are exempt (D13) and
/// the primary is never its own victim (docs/02-domain.md §12), so no
/// eligible victim can restore the bound (D19). See the file header for why
/// this path is proved at the planner seam instead of end-to-end.
@Test func allPinnedInventoryAtTheHardBoundRejectsCaptureAtThePlannerSeam() throws {
    // The complete retained inventory: three pinned items with contiguous
    // ordinals (D12), so after projection the only unpinned item would be
    // the primary itself.
    let pinnedSummaries = (0..<3).map { index in
        RetainedItemSummary(
            id: HistoryItemID(rawValue: UUID()),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 700_040_000 + Double(index) * 100),
            pinOrdinal: PinOrdinal(rawValue: index)
        )
    }
    let facts = IngestFacts(
        hintedItem: nil,
        candidates: CompleteDedupCandidates(items: []),
        retention: CompleteRetentionInventory(allItems: pinnedSummaries)
    )

    // A valid one-representation prepared capture; with no hint and no
    // candidates it can only take the insert lane (docs/02-domain.md §9.3).
    let capture = PreparedCapture(
        candidateID: HistoryItemID(rawValue: UUID()),
        canonical: try CanonicalContent(representations: [
            CanonicalRepresentation(
                content: ContentRepresentation(
                    typeIdentifier: "public.utf8-plain-text",
                    bytes: Data("ws9 capacity probe".utf8)
                ),
                fingerprint: ContentFingerprint(rawValue: 0x0009_0001)
            ),
        ]),
        origin: CopyOrigin(lineageHint: nil, sourceApplication: "com.example.ws9"),
        observedAt: Date(timeIntervalSinceReferenceDate: 700_040_300)
    )

    // WS9: the insert would push the retained total to 4 against a hard
    // bound of 3 (the current retained count), and the eligible victim set
    // is EMPTY — every retained item is pinned and the primary is exempt —
    // so planning fails closed (docs/02-domain.md §12, D19). The user policy
    // alone (at least one unpinned slot) can never force this failure.
    #expect(throws: DomainRejection.capacityExceeded(.retainedItems)) {
        try planCapture(
            capture,
            facts: facts,
            retention: RetentionPolicy(maximumUnpinnedItems: 1),
            hardMaximumRetainedItems: pinnedSummaries.count
        )
    }
}
}
