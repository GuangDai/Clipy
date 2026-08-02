/// WS16 — Remove and not-found failures (docs/06-cross-cutting.md §8 WS16):
/// the commit/receipt/storage side of `perform(.remove(_:))` through the
/// public `SwiftDataHistory` facade and the real step-6 mutation commit
/// paths, plus the `.notFound` / `.invalidPinnedPlacement` failure producers
/// on an absent ID.
///
/// Phasing (docs/roadmap/README.md §3, WS-clause phasing note): WS16's "the
/// ID absent from subsequent browse/detail/paste" clause is a step-7 (reads +
/// observation) clause and is NOT asserted here — `browse`, `details(for:)`,
/// and `pastePayload(for:)` still throw the internal `StepDeferredError`.
/// This file closes the step-6 clauses — the `.committed` receipt with
/// `.removed(count: 1)` and Change Position advanced exactly once; the
/// pinned-lane compaction inside the remove commit (AUDIT IMP6-01,
/// docs/02-domain.md §10: the survivors re-zip against `0 ..< count` in the
/// SAME commit, so D12 holds and the final-order revalidation cannot gap);
/// the failure vocabulary — `.remove`, `.unpin`, and `.revise` on an absent
/// ID throw `.notFound(id)` while `.placePinned` throws
/// `.invalidPinnedPlacement(.targetMissing)`, placement's own anchor-missing
/// vocabulary by design (docs/03b-instruction-set.md §10
/// `PinnedPlacementFailure`); and the durable row/singleton state as seen
/// through an INDEPENDENT second `ModelContainer` over the same on-disk
/// store (see `WSSupport`).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS16RemoveAndNotFoundTests {

/// WS16 (docs/06-cross-cutting.md §8): removing the only retained item is one
/// History Commit with outcome `.removed(count: 1)`, Change Position advances
/// exactly once (1 → 2), and the durable store shows zero rows with the
/// position singleton at the receipt's position.
@Test func removeOfUnpinnedItemCommitsRemovedCount1AdvancesPositionOnceAndLeavesNoRows() async throws {
    let storeURL = WSSupport.tempStoreURL("ws16-remove-unpinned")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: one normalized raw text capture on an empty store (as WS1).
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_030_000)
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws16 plain removal",
            observedAt: observedAt,
            source: "com.example.ws16.plain"
        )
    ))
    guard case let .committed(captureCommit) = captureReceipt,
          case let .inserted(reference) = captureCommit.outcome
    else {
        Issue.record("WS16 arrange: expected .committed(.inserted), got \(captureReceipt)")
        return
    }
    #expect(captureCommit.position.rawValue == 1)

    // Act: remove the only retained item.
    let receipt = try await history.perform(.remove(reference.id))

    // WS16: the remove is a History Commit (not `.unchanged`).
    guard case let .committed(commit) = receipt else {
        Issue.record("WS16: expected a .committed receipt, got \(receipt)")
        return
    }
    // WS16: "ChangePosition advanced once" — the second commit moves the
    // singleton 1 → 2 (docs/05-authority-kernel.md §3.2).
    #expect(commit.position.rawValue == 2)
    // WS16: "Expect .removed(count: 1)" — exactly one item retired.
    guard case .removed(count: 1) = commit.outcome else {
        Issue.record("WS16: expected .removed(count: 1), got \(commit.outcome)")
        return
    }

    // Storage side, through the INDEPENDENT container: the row is gone (D15 —
    // removal is absence from the retained set, there is no tombstone) and
    // the position singleton matches the receipt (one transaction,
    // docs/06-cross-cutting.md §7.1).
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.isEmpty)
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 2)
}

/// WS16 (docs/06-cross-cutting.md §8) + AUDIT IMP6-01 (docs/02-domain.md
/// §10): removing the FIRST of three pinned items compacts the pinned lane in
/// the same commit — the two survivors keep their original relative order and
/// their ordinals re-zip to exactly 0 and 1 (D12 preserved) — while the
/// commit reports `.removed(count: 1)` and advances Change Position once.
@Test func removeOfFirstPinnedItemCompactsSurvivorOrdinalsToZeroAndOneInTheSameCommit() async throws {
    let storeURL = WSSupport.tempStoreURL("ws16-remove-pinned-compacts")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: three DISTINCT text captures (identical content would
    // coalesce, docs/02-domain.md §9) at monotone fixed observation times.
    let firstObservedAt = Date(timeIntervalSinceReferenceDate: 700_031_000)
    let secondObservedAt = Date(timeIntervalSinceReferenceDate: 700_031_100)
    let thirdObservedAt = Date(timeIntervalSinceReferenceDate: 700_031_200)

    let firstCapture = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws16 pinned lane one",
            observedAt: firstObservedAt,
            source: "com.example.ws16.one"
        )
    ))
    guard case let .committed(firstCaptureCommit) = firstCapture,
          case let .inserted(firstReference) = firstCaptureCommit.outcome
    else {
        Issue.record("WS16 arrange: expected .committed(.inserted), got \(firstCapture)")
        return
    }
    #expect(firstCaptureCommit.position.rawValue == 1)

    let secondCapture = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws16 pinned lane two",
            observedAt: secondObservedAt,
            source: "com.example.ws16.two"
        )
    ))
    guard case let .committed(secondCaptureCommit) = secondCapture,
          case let .inserted(secondReference) = secondCaptureCommit.outcome
    else {
        Issue.record("WS16 arrange: expected .committed(.inserted), got \(secondCapture)")
        return
    }
    #expect(secondCaptureCommit.position.rawValue == 2)

    let thirdCapture = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws16 pinned lane three",
            observedAt: thirdObservedAt,
            source: "com.example.ws16.three"
        )
    ))
    guard case let .committed(thirdCaptureCommit) = thirdCapture,
          case let .inserted(thirdReference) = thirdCaptureCommit.outcome
    else {
        Issue.record("WS16 arrange: expected .committed(.inserted), got \(thirdCapture)")
        return
    }
    #expect(thirdCaptureCommit.position.rawValue == 3)

    // Pin all three in capture order (`.last` each time): every placement is
    // one History Commit with outcome `.placedPinned(id)` (docs/02-domain.md
    // §10), so the lane becomes [first: 0, second: 1, third: 2] at Change
    // Positions 4–6.
    let firstPin = try await history.perform(.placePinned(firstReference.id, at: .last))
    guard case let .committed(firstPinCommit) = firstPin,
          case let .placedPinned(firstPinnedID) = firstPinCommit.outcome
    else {
        Issue.record("WS16 arrange: expected .committed(.placedPinned), got \(firstPin)")
        return
    }
    #expect(firstPinnedID == firstReference.id)
    #expect(firstPinCommit.position.rawValue == 4)

    let secondPin = try await history.perform(.placePinned(secondReference.id, at: .last))
    guard case let .committed(secondPinCommit) = secondPin,
          case let .placedPinned(secondPinnedID) = secondPinCommit.outcome
    else {
        Issue.record("WS16 arrange: expected .committed(.placedPinned), got \(secondPin)")
        return
    }
    #expect(secondPinnedID == secondReference.id)
    #expect(secondPinCommit.position.rawValue == 5)

    let thirdPin = try await history.perform(.placePinned(thirdReference.id, at: .last))
    guard case let .committed(thirdPinCommit) = thirdPin,
          case let .placedPinned(thirdPinnedID) = thirdPinCommit.outcome
    else {
        Issue.record("WS16 arrange: expected .committed(.placedPinned), got \(thirdPin)")
        return
    }
    #expect(thirdPinnedID == thirdReference.id)
    #expect(thirdPinCommit.position.rawValue == 6)

    // Pre-remove durable state through the INDEPENDENT container: the pinned
    // lane is exactly [first: 0, second: 1, third: 2] — the ordinals the
    // compaction below must shift from.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let preRemovalRows = try WSSupport.fetchRows(container)
    #expect(preRemovalRows.count == 3)
    let preRemovalOrdinals = Dictionary(
        uniqueKeysWithValues: preRemovalRows.map { ($0.id, $0.pinOrdinal) }
    )
    #expect(preRemovalOrdinals == [
        firstReference.id.rawValue: 0,
        secondReference.id.rawValue: 1,
        thirdReference.id.rawValue: 2,
    ])

    // Act: remove the FIRST pinned item.
    let receipt = try await history.perform(.remove(firstReference.id))

    // WS16: one History Commit, `.removed(count: 1)`, Change Position
    // advanced once (6 → 7).
    guard case let .committed(commit) = receipt else {
        Issue.record("WS16: expected a .committed receipt, got \(receipt)")
        return
    }
    #expect(commit.position.rawValue == 7)
    guard case .removed(count: 1) = commit.outcome else {
        Issue.record("WS16: expected .removed(count: 1), got \(commit.outcome)")
        return
    }

    // WS16 + AUDIT IMP6-01 (docs/02-domain.md §10): the same commit compacted
    // the lane — the survivors hold ordinals 0 and 1 in their ORIGINAL
    // relative order (second before third), so D12 (contiguous ordinals from
    // 0) holds and the Part V §10 final-order revalidation cannot fail on a
    // gap. Pin mutations never advance Content Version (docs/02-domain.md
    // §10), so both survivors stay at their capture-time version.
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.count == 2)
    #expect(!rows.contains(where: { $0.id == firstReference.id.rawValue }))
    let secondRow = try #require(rows.first(where: { $0.id == secondReference.id.rawValue }))
    let thirdRow = try #require(rows.first(where: { $0.id == thirdReference.id.rawValue }))
    #expect(secondRow.pinOrdinal == 0)
    #expect(thirdRow.pinOrdinal == 1)
    #expect(secondRow.contentVersionRaw == 1)
    #expect(thirdRow.contentVersionRaw == 1)

    // The durable singleton matches the receipt's position (one transaction,
    // docs/06-cross-cutting.md §7.1).
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 7)
}

/// WS16 (docs/06-cross-cutting.md §8): on an absent ID, `.remove`, `.unpin`,
/// and `.revise` throw `.notFound(id)` (docs/02-domain.md §6 — those planners
/// reject a missing target as `.notFound`), while `.placePinned` throws
/// `.invalidPinnedPlacement(.targetMissing)` — placement's own vocabulary by
/// design (docs/03b-instruction-set.md §10). No rejected action is a History
/// Commit: the position singleton and the empty store are unchanged.
@Test func absentIDYieldsNotFoundForRemoveUnpinReviseAndTargetMissingForPlacePinned() async throws {
    let storeURL = WSSupport.tempStoreURL("ws16-not-found-vocabulary")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: capture one item and remove it — every action below targets
    // the now-absent ID.
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_032_000)
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws16 absent target",
            observedAt: observedAt,
            source: "com.example.ws16.absent"
        )
    ))
    guard case let .committed(captureCommit) = captureReceipt,
          case let .inserted(reference) = captureCommit.outcome
    else {
        Issue.record("WS16 arrange: expected .committed(.inserted), got \(captureReceipt)")
        return
    }
    #expect(captureCommit.position.rawValue == 1)

    let removeReceipt = try await history.perform(.remove(reference.id))
    guard case let .committed(removeCommit) = removeReceipt,
          case .removed(count: 1) = removeCommit.outcome
    else {
        Issue.record("WS16 arrange: expected .committed(.removed(count: 1)), got \(removeReceipt)")
        return
    }
    #expect(removeCommit.position.rawValue == 2)

    let absentID = reference.id

    // WS16: "A later .remove … on the absent ID returns .notFound"
    // (docs/06-cross-cutting.md §8 WS16).
    await #expect(throws: HistoryFailure.notFound(absentID)) {
        try await history.perform(.remove(absentID))
    }
    // WS16: ".unpin … on the absent ID returns .notFound" — unpin rejects a
    // missing target as `.notFound` (docs/02-domain.md §6, §10).
    await #expect(throws: HistoryFailure.notFound(absentID)) {
        try await history.perform(.unpin(absentID))
    }
    // WS16: ".revise … on the absent ID returns .notFound" — the §6.2
    // preparation snapshot fetches the target first and throws `.notFound`
    // before any draft resolution runs (docs/05-authority-kernel.md §6.2).
    // The OCC token is the item's real capture-time Content Version.
    await #expect(throws: HistoryFailure.notFound(absentID)) {
        try await history.perform(.revise(RevisionRequest(
            itemID: absentID,
            expected: reference.contentVersion,
            intent: .revert(to: .canonical)
        )))
    }
    // WS16: ".placePinned returns .invalidPinnedPlacement(.targetMissing) —
    // placement uses its own anchor-missing vocabulary by design"
    // (docs/03b-instruction-set.md §10 `PinnedPlacementFailure`;
    // docs/02-domain.md §10 step 1).
    await #expect(throws: HistoryFailure.invalidPinnedPlacement(.targetMissing)) {
        try await history.perform(.placePinned(absentID, at: .last))
    }

    // No rejected action is a History Commit (docs/04-coherence.md §4): the
    // position singleton stays at 2 and the store stays empty.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.isEmpty)
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 2)
}
}
