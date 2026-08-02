/// WS10 — Clear atomicity (docs/06-cross-cutting.md §8 WS10): the
/// commit/receipt/storage side of `.clear(.unpinned)` and `.clear(.all)`
/// through the public `SwiftDataHistory.perform(_:)` facade and the real
/// `HistoryAuthority` clear commit path.
///
/// Phasing (docs/roadmap/README.md §3, WS-clause phasing note): WS10's
/// "No partial page is observable" clause is a public-read (observed page)
/// clause and DEFERS to step 7 (reads + observation) — it is NOT asserted
/// here. This file closes the step-6 commit-side clauses: `.clear(.unpinned)`
/// removes the COMPLETE unpinned set in one History Commit and preserves
/// pins — the pinned survivors keep their IDs, Canonical bytes, Content
/// Versions, and exact `0 ..< pinnedCount` ordinals, because a clear of
/// unpinned items never disturbs the pinned lane (docs/02-domain.md §5.4
/// "There is no partial clear", D12); `.clear(.all)` removes all remaining
/// rows in one later commit; Change Position advances exactly once per clear
/// commit regardless of row count (docs/02-domain.md D6,
/// docs/05-authority-kernel.md §3.2); and a clear whose affected set is
/// empty is `.unchanged` with NO position advance (docs/02-domain.md §7: a
/// commit's mutation list is non-empty; §8 `planClear`). Row-level state is
/// asserted through the INDEPENDENT second `ModelContainer` over the same
/// on-disk store (see `WSSupport`).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS10ClearAtomicityTests {

/// Deterministic scenario constants: four distinct single-line texts (the
/// §15 projection stays deterministic and no two captures coalesce), fixed
/// monotone observation times, and one distinct observed source per item.
private static let texts = [
    "ws10 clear atomicity alpha",
    "ws10 clear atomicity bravo",
    "ws10 clear atomicity charlie",
    "ws10 clear atomicity delta",
]
private static let observedAts = [
    Date(timeIntervalSinceReferenceDate: 700_020_000),
    Date(timeIntervalSinceReferenceDate: 700_020_100),
    Date(timeIntervalSinceReferenceDate: 700_020_200),
    Date(timeIntervalSinceReferenceDate: 700_020_300),
]
private static let sources = [
    "com.example.ws10.alpha",
    "com.example.ws10.bravo",
    "com.example.ws10.charlie",
    "com.example.ws10.delta",
]

/// WS10 arrange: four distinct raw text captures (commits 1–4), then pins
/// bravo (index 1) and delta (index 3) at the back of the pinned lane
/// (commits 5–6) — interleaving pinned and unpinned items so the clear must
/// select by pin state, and `.last` placement twice yielding ordinals 0 and
/// 1 in pin order (docs/02-domain.md §10 steps 3–4). Returns `nil` after
/// recording an issue if any arrange receipt is not the expected commit.
private static func arrangeFourItemsTwoPinned(
    on history: SwiftDataHistory
) async throws -> (pinnedIDs: [HistoryItemID], unpinnedIDs: [HistoryItemID])? {
    var insertedIDs: [HistoryItemID] = []
    for index in texts.indices {
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                texts[index],
                observedAt: observedAts[index],
                source: sources[index]
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome
        else {
            Issue.record("WS10 arrange: expected .committed(.inserted) for capture \(index), got \(receipt)")
            return nil
        }
        insertedIDs.append(reference.id)
    }
    let pinnedIDs = [insertedIDs[1], insertedIDs[3]]
    let unpinnedIDs = [insertedIDs[0], insertedIDs[2]]
    for pinnedID in pinnedIDs {
        let receipt = try await history.perform(.placePinned(pinnedID, at: .last))
        guard case let .committed(commit) = receipt,
              case let .placedPinned(placedID) = commit.outcome,
              placedID == pinnedID
        else {
            Issue.record("WS10 arrange: expected .committed(.placedPinned) for \(pinnedID), got \(receipt)")
            return nil
        }
    }
    return (pinnedIDs: pinnedIDs, unpinnedIDs: unpinnedIDs)
}

/// WS10 (docs/06-cross-cutting.md §8): `.clear(.unpinned)` retires the
/// complete unpinned set in ONE History Commit — `.cleared(count: 2)` at a
/// single advanced position — and preserves pins: exactly the two pinned
/// rows survive, bytes and versions intact, ordinals still exactly 0 ..< 2
/// in pin order (docs/02-domain.md §5.4, D12).
@Test func clearUnpinnedRetiresCompleteUnpinnedSetInOneCommitPreservingPinnedLaneAndOrdinals() async throws {
    let storeURL = WSSupport.tempStoreURL("ws10-clear-unpinned")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: four items (commits 1–4), bravo and delta pinned (commits 5–6).
    guard let arranged = try await Self.arrangeFourItemsTwoPinned(on: history) else { return }

    // Act: one `.clear(.unpinned)`.
    let receipt = try await history.perform(.clear(.unpinned))

    // WS10: the clear is a History Commit (not `.unchanged`) — the affected
    // set is non-empty.
    guard case let .committed(commit) = receipt else {
        Issue.record("WS10: expected a .committed receipt for .clear(.unpinned), got \(receipt)")
        return
    }
    // WS10: Change Position 7 — the complete unpinned set retires in one
    // commit, so the position advances exactly once for the whole clear
    // (docs/02-domain.md D6; docs/05-authority-kernel.md §3.2).
    #expect(commit.position.rawValue == 7)
    guard case let .cleared(count) = commit.outcome else {
        Issue.record("WS10: expected .cleared(count:) for .clear(.unpinned), got \(commit.outcome)")
        return
    }
    // WS10: "removes the complete unpinned set in one commit" — both
    // unpinned items (alpha and charlie) in the one commit's count.
    #expect(count == 2)

    // Storage side, through the INDEPENDENT container: ONLY the two pinned
    // rows survive — the complete unpinned set is gone, no partial clear
    // (docs/02-domain.md §5.4).
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.id)) == Set(arranged.pinnedIDs.map(\.rawValue)))

    // WS10: "preserves pins" — the pinned lane is undisturbed: ordinals are
    // still exactly 0 ..< 2 in pin order, bravo at 0 and delta at 1
    // (docs/02-domain.md D12; §5.4: `.unpinned` retains every pinned item).
    let bravoRow = try #require(rows.first(where: { $0.id == arranged.pinnedIDs[0].rawValue }))
    let deltaRow = try #require(rows.first(where: { $0.id == arranged.pinnedIDs[1].rawValue }))
    #expect(bravoRow.pinOrdinal == 0)
    #expect(deltaRow.pinOrdinal == 1)

    // The survivors are fully intact — initial Content Version, one
    // occurrence, Canonical bytes byte-exact: a clear touches only its
    // affected set (docs/02-domain.md §5.4, §8 `planClear`).
    let survivors: [(row: HistoryItemRow, text: String)] = [
        (bravoRow, Self.texts[1]),
        (deltaRow, Self.texts[3]),
    ]
    for survivor in survivors {
        #expect(survivor.row.contentVersionRaw == 1)
        #expect(survivor.row.copyCount == 1)
        let canonical = try CanonicalBlobCodec.decode(survivor.row.canonicalBlob)
        #expect(canonical.representations.map(\.content.typeIdentifier) == ["public.utf8-plain-text"])
        #expect(canonical.representations.map(\.content.bytes) == [Data(survivor.text.utf8)])
    }

    // WS10: the durable singleton matches the receipt's position — one
    // commit for the whole clear (docs/06-cross-cutting.md §7.1).
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 7)
}

/// WS10 (docs/06-cross-cutting.md §8): `.clear(.all)` after the unpinned
/// clear retires every remaining row (the two pinned survivors) in ONE later
/// History Commit — `.cleared(count: 2)`, the position advanced exactly once
/// more, zero rows left. A further `.clear(.all)` on the now-empty store is
/// `.unchanged`: an empty affected set is no commit (docs/02-domain.md §7 —
/// a commit's mutation list is non-empty; §8 `planClear`), so the position
/// does NOT advance.
@Test func clearAllRetiresRemainingRowsInOneCommitAndEmptyClearIsUnchangedWithoutAdvance() async throws {
    let storeURL = WSSupport.tempStoreURL("ws10-clear-all")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: the same four-items-two-pinned store (commits 1–6), then the
    // unpinned pair retired first (commit 7), so the `.all` clear below acts
    // on exactly the two pinned survivors.
    guard try await Self.arrangeFourItemsTwoPinned(on: history) != nil else { return }
    let unpinnedClearReceipt = try await history.perform(.clear(.unpinned))
    guard case let .committed(unpinnedClearCommit) = unpinnedClearReceipt,
          case let .cleared(unpinnedClearedCount) = unpinnedClearCommit.outcome,
          unpinnedClearedCount == 2
    else {
        Issue.record("WS10 arrange: expected .committed(.cleared(count: 2)) for .clear(.unpinned), got \(unpinnedClearReceipt)")
        return
    }

    // Act: `.clear(.all)` removes all remaining rows in one later commit.
    let receipt = try await history.perform(.clear(.all))

    // WS10: the clear is a History Commit carrying `.cleared`.
    guard case let .committed(commit) = receipt else {
        Issue.record("WS10: expected a .committed receipt for .clear(.all), got \(receipt)")
        return
    }
    // WS10: Change Position 8 — one advance for the whole clear, exactly
    // once more than the unpinned clear (docs/02-domain.md D6).
    #expect(commit.position.rawValue == 8)
    guard case let .cleared(count) = commit.outcome else {
        Issue.record("WS10: expected .cleared(count:) for .clear(.all), got \(commit.outcome)")
        return
    }
    // WS10: "removes all remaining rows in one later commit" — the two
    // pinned survivors are not protected from `.all` (docs/02-domain.md
    // §5.4: `.all` removes every item).
    #expect(count == 2)

    // Storage side, through the INDEPENDENT container: ZERO rows remain.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rowsAfterClearAll = try WSSupport.fetchRows(container)
    #expect(rowsAfterClearAll.isEmpty)
    // WS10: the durable singleton matches the receipt's position.
    let positionAfterClearAll = try WSSupport.fetchPosition(container)
    #expect(positionAfterClearAll.rawValue == 8)

    // Act: a third `.clear(.all)` on the empty store. The affected set is
    // empty, so there is no commit (docs/02-domain.md §7: a commit's
    // mutation list is non-empty; §8 `planClear`: empty affected set is
    // `.unchanged`, never a rejection).
    let emptyClearReceipt = try await history.perform(.clear(.all))
    guard case .unchanged = emptyClearReceipt else {
        Issue.record("WS10: expected .unchanged clearing an empty store, got \(emptyClearReceipt)")
        return
    }
    // WS10: the position does NOT advance for a no-op clear — the singleton
    // is still 8 and the store is still empty (docs/04-coherence.md §4: no
    // position or invalidation without a durable mutation).
    let positionAfterNoop = try WSSupport.fetchPosition(container)
    #expect(positionAfterNoop.rawValue == 8)
    let rowsAfterNoop = try WSSupport.fetchRows(container)
    #expect(rowsAfterNoop.isEmpty)
}
}
