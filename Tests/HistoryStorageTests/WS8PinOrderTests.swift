/// WS8 — Pin order (docs/06-cross-cutting.md §8 WS8): the
/// commit/receipt/storage side of pinning three items, moving the last
/// before the first, and unpinning the item now occupying the middle
/// position, through the public `SwiftDataHistory.perform(.placePinned(_:at:))`
/// / `.unpin(_:)` and the real step-6 mutation commit path
/// (`HistoryAuthority.commitPinnedPlacement` / `commitUnpin`;
/// docs/02-domain.md §10, docs/05-authority-kernel.md §9).
///
/// This file closes WS8's step-6 commit clauses; the separately landed
/// step-7 read suites own the public-order clause. It asserts the
/// `.placedPinned(id)` /
/// `.unpinned(id)` receipt outcomes, exactly one Change Position advance per
/// non-no-op action and no advance for a no-op placement (docs/02-domain.md
/// §13), Content Version untouched by pin/reorder/unpin (§13: `.assignPin`
/// preserves), a RESTART after each receipt (reopening the facade reruns the
/// docs/05-authority-kernel.md §13 startup, whose step 9 revalidates the full
/// pinned ordinal set from scalar fields), and stored pin ordinals unique and
/// exactly `0 ..< pinnedCount` (D12) with the expected id→ordinal mapping,
/// all as seen through an INDEPENDENT second `ModelContainer` over the same
/// on-disk store (see `WSSupport`).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS8PinOrderTests {

/// Receipt-side assertion for one committed `.placePinned`: a `.committed`
/// receipt carrying `.placedPinned(expectedID)` at exactly `expectedPosition`
/// — the one Change Position advance the action earns
/// (docs/02-domain.md §13; docs/03a-instruction-set.md §6).
private static func expectPlacedPinned(
    _ receipt: HistoryReceipt,
    id expectedID: HistoryItemID,
    position expectedPosition: UInt64,
    _ clause: String
) {
    guard case let .committed(commit) = receipt else {
        Issue.record("WS8 (\(clause)): expected a .committed receipt, got \(receipt)")
        return
    }
    #expect(
        commit.position.rawValue == expectedPosition,
        "WS8 (\(clause)): the non-no-op action advances Change Position exactly once"
    )
    guard case let .placedPinned(placedID) = commit.outcome else {
        Issue.record("WS8 (\(clause)): expected .placedPinned(id), got \(commit.outcome)")
        return
    }
    #expect(
        placedID == expectedID,
        "WS8 (\(clause)): the placed item is the placement target"
    )
}

/// Receipt-side assertion for one committed `.unpin`: a `.committed` receipt
/// carrying `.unpinned(expectedID)` at exactly `expectedPosition`
/// (docs/02-domain.md §13; docs/03a-instruction-set.md §6).
private static func expectUnpinned(
    _ receipt: HistoryReceipt,
    id expectedID: HistoryItemID,
    position expectedPosition: UInt64,
    _ clause: String
) {
    guard case let .committed(commit) = receipt else {
        Issue.record("WS8 (\(clause)): expected a .committed receipt, got \(receipt)")
        return
    }
    #expect(
        commit.position.rawValue == expectedPosition,
        "WS8 (\(clause)): the non-no-op action advances Change Position exactly once"
    )
    guard case let .unpinned(unpinnedID) = commit.outcome else {
        Issue.record("WS8 (\(clause)): expected .unpinned(id), got \(commit.outcome)")
        return
    }
    #expect(
        unpinnedID == expectedID,
        "WS8 (\(clause)): the unpinned item is the unpin target"
    )
}

/// WS8: "After each receipt, restart and assert … stored ordinals are unique
/// and exactly `0 ..< count`." Reopens the facade over the same on-disk store
/// — the docs/05-authority-kernel.md §13 startup (step 9) revalidates the
/// full pinned ordinal set, so a successful open re-proves the durable lane —
/// then asserts the exact id→ordinal mapping (`nil` is unpinned,
/// docs/05-authority-kernel.md §3.1), D12 uniqueness/contiguity, preserved
/// Content Versions, and the durable position through the INDEPENDENT second
/// container. Returns the restarted facade so the scenario continues through
/// the reopened store.
private static func restartAndAssertStoredPinState(
    storeURL: URL,
    expectedOrdinals: [UUID: Int?],
    expectedPosition: UInt64,
    _ clause: String
) async throws -> SwiftDataHistory {
    let restarted = try await WSSupport.openHistory(storeURL: storeURL)

    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(
        rows.count == expectedOrdinals.count,
        "WS8 (\(clause)): exactly the three captured items are retained"
    )
    var pinnedOrdinals: [Int] = []
    for row in rows {
        let expectedOrdinal = try #require(
            expectedOrdinals[row.id],
            "WS8 (\(clause)): every retained row is one of the three captured items"
        )
        #expect(
            row.pinOrdinal == expectedOrdinal,
            "WS8 (\(clause)): stored pin ordinal matches the expected id→ordinal mapping"
        )
        // Pin/reorder/unpin never advances Content Version
        // (docs/02-domain.md §13: `.assignPin` preserves).
        #expect(
            row.contentVersionRaw == 1,
            "WS8 (\(clause)): Content Version remains unchanged"
        )
        if let ordinal = row.pinOrdinal {
            pinnedOrdinals.append(ordinal)
        }
    }
    // D12: retained pinned ordinals are unique and exactly `0 ..< pinnedCount`.
    #expect(
        Set(pinnedOrdinals).count == pinnedOrdinals.count,
        "WS8 (\(clause)): stored pin ordinals are unique (D12)"
    )
    #expect(
        Set(pinnedOrdinals) == Set(0 ..< pinnedOrdinals.count),
        "WS8 (\(clause)): stored pin ordinals are exactly 0 ..< pinnedCount (D12)"
    )

    // The durable singleton matches the receipt-side position; for a no-op
    // receipt this is the proof that the position did NOT advance.
    let position = try WSSupport.fetchPosition(container)
    #expect(
        position.rawValue == expectedPosition,
        "WS8 (\(clause)): the durable Change Position matches the receipt"
    )

    return restarted
}

/// WS8 (docs/06-cross-cutting.md §8): pin three items (a→0, b→1, c→2), move
/// the last before the first (c→0, a→1, b→2), then unpin the item now
/// occupying the middle position (c→0, b→1, a unpinned). Each non-no-op
/// action returns `.placedPinned(id)` / `.unpinned(id)` and advances Change
/// Position exactly once; a `.last` placement on the already-last item is a
/// true no-op returning `.unchanged` with no position advance; Content
/// Versions stay at 1 throughout; after each receipt a restart plus the
/// independent container proves the stored ordinals unique and exactly
/// `0 ..< pinnedCount` with the expected mapping (D12).
@Test func pinReorderAndUnpinKeepContiguousOrdinalsAcrossRestarts() async throws {
    let storeURL = WSSupport.tempStoreURL("ws8-pin-order")
    defer { WSSupport.removeStore(storeURL) }
    var history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: three distinct normalized raw text captures (the WS1 path
    // this gate builds on), fixed monotone observation times, one observed
    // source each. They occupy Change Positions 1–3, so the pin actions
    // below commit at positions 4–8.
    let captureA = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws8 pin order item a",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_020_000),
            source: "com.example.ws8.a"
        )
    ))
    guard case let .committed(commitA) = captureA,
          case let .inserted(referenceA) = commitA.outcome
    else {
        Issue.record("WS8 arrange: expected .committed(.inserted) for item a, got \(captureA)")
        return
    }
    let captureB = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws8 pin order item b",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_020_100),
            source: "com.example.ws8.b"
        )
    ))
    guard case let .committed(commitB) = captureB,
          case let .inserted(referenceB) = commitB.outcome
    else {
        Issue.record("WS8 arrange: expected .committed(.inserted) for item b, got \(captureB)")
        return
    }
    let captureC = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws8 pin order item c",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_020_200),
            source: "com.example.ws8.c"
        )
    ))
    guard case let .committed(commitC) = captureC,
          case let .inserted(referenceC) = commitC.outcome
    else {
        Issue.record("WS8 arrange: expected .committed(.inserted) for item c, got \(captureC)")
        return
    }
    let idA = referenceA.id
    let idB = referenceB.id
    let idC = referenceC.id

    // WS8: "Pin three items" — first pins with `.last` append to the pinned
    // lane (docs/02-domain.md §10 steps 2–3): a→0.
    let pinA = try await history.perform(.placePinned(idA, at: .last))
    Self.expectPlacedPinned(pinA, id: idA, position: 4, "pin a .last")
    history = try await Self.restartAndAssertStoredPinState(
        storeURL: storeURL,
        expectedOrdinals: [idA.rawValue: 0, idB.rawValue: nil, idC.rawValue: nil],
        expectedPosition: 4,
        "pin a .last"
    )

    // b→1.
    let pinB = try await history.perform(.placePinned(idB, at: .last))
    Self.expectPlacedPinned(pinB, id: idB, position: 5, "pin b .last")
    history = try await Self.restartAndAssertStoredPinState(
        storeURL: storeURL,
        expectedOrdinals: [idA.rawValue: 0, idB.rawValue: 1, idC.rawValue: nil],
        expectedPosition: 5,
        "pin b .last"
    )

    // c→2.
    let pinC = try await history.perform(.placePinned(idC, at: .last))
    Self.expectPlacedPinned(pinC, id: idC, position: 6, "pin c .last")
    history = try await Self.restartAndAssertStoredPinState(
        storeURL: storeURL,
        expectedOrdinals: [idA.rawValue: 0, idB.rawValue: 1, idC.rawValue: 2],
        expectedPosition: 6,
        "pin c .last"
    )

    // WS8: "move the last before the first" — `.before(a)` reorders the lane
    // [a, b, c] → [c, a, b] (docs/02-domain.md §10 steps 2–4): c→0, a→1, b→2.
    let move = try await history.perform(.placePinned(idC, at: .before(idA)))
    Self.expectPlacedPinned(move, id: idC, position: 7, "move c .before(a)")
    history = try await Self.restartAndAssertStoredPinState(
        storeURL: storeURL,
        expectedOrdinals: [idC.rawValue: 0, idA.rawValue: 1, idB.rawValue: 2],
        expectedPosition: 7,
        "move c .before(a)"
    )

    // WS8: "each non-no-op action advances Change Position once" — and a
    // placement that reproduces the existing order is a true no-op
    // (docs/02-domain.md §10 step 5): b is already last in [c, a, b], so
    // `.last` returns `.unchanged` — no position, no invalidation, no durable
    // mutation (docs/03a-instruction-set.md §6).
    let noop = try await history.perform(.placePinned(idB, at: .last))
    guard case .unchanged = noop else {
        Issue.record("WS8 (no-op b .last): expected .unchanged, got \(noop)")
        return
    }
    history = try await Self.restartAndAssertStoredPinState(
        storeURL: storeURL,
        expectedOrdinals: [idC.rawValue: 0, idA.rawValue: 1, idB.rawValue: 2],
        expectedPosition: 7,
        "no-op b .last"
    )

    // WS8: "unpin the item now occupying the middle position" — a sits
    // between c and b in [c, a, b]; unpinning removes it from the lane and
    // shifts the later ordinals down (docs/02-domain.md §10): [c, b] with
    // c→0, b→1, and a unpinned (`nil` ordinal, docs/05-authority-kernel.md
    // §3.1).
    let unpin = try await history.perform(.unpin(idA))
    Self.expectUnpinned(unpin, id: idA, position: 8, "unpin a (middle)")
    history = try await Self.restartAndAssertStoredPinState(
        storeURL: storeURL,
        expectedOrdinals: [idC.rawValue: 0, idB.rawValue: 1, idA.rawValue: nil],
        expectedPosition: 8,
        "unpin a (middle)"
    )
}
}
