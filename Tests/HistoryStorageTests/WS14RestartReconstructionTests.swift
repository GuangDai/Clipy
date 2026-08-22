/// WS14 — Restart reconstruction (docs/06-cross-cutting.md §8 WS14): the
/// commit/receipt/storage side of "After insert, coalesce, pin reorder, and
/// multiple revisions, reopen the store." One on-disk store accumulates an
/// insert, a Copy Coalescing fold, three first-pins and a `.before` reorder,
/// and two byte-changing `.replace` revisions of the same item through the
/// public `SwiftDataHistory.perform` and the real step-6 mutation commit
/// paths (docs/02-domain.md §10/§11, docs/05-authority-kernel.md §9); the
/// facade is then REOPENED over the same store, rerunning the
/// docs/05-authority-kernel.md §13 startup, whose steps 5–9 rebuild the
/// complete Signature Index from durable signature metadata without decoding
/// content blobs and revalidate the full pinned ordinal set.
///
/// This file closes WS14's step-6 durable-reconstruction clauses; the
/// separately landed step-7 read suites own the public-result clauses. All
/// assertions are seen through an INDEPENDENT second `ModelContainer` over the same on-disk
/// store (see `WSSupport`): (i) the position singleton equals the
/// pre-restart commit count; (ii) every row's Content Version, occurrence
/// fields, §15 projection fields, and pin ordinal match the pre-restart
/// values, with stored pin ordinals unique and exactly `0 ..< pinnedCount`
/// (D12); (iii) the revision blob decodes to the full append-only list with
/// the correct active Revision ID, Effective Content (docs/02-domain.md
/// §2.6) being the active revision's complete snapshot; and (iv) the rebuilt
/// Signature Index is COMPLETE — a post-restart capture of the revised
/// item's Canonical bytes coalesces into it (receipt `.coalesced` with the
/// same History Item ID at the preserved Content Version) instead of
/// inserting a duplicate row, proving candidacy was re-proven from durable
/// state (revisions never rewrite the Canonical signature used by general
/// deduplication, docs/02-domain.md §2.6).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS14RestartReconstructionTests {

/// Receipt-side assertion for one committed `.placePinned`: a `.committed`
/// receipt carrying `.placedPinned(expectedID)` at exactly `expectedPosition`
/// — the one Change Position advance the placement earns
/// (docs/02-domain.md §13; docs/03a-instruction-set.md §6).
private static func expectPlacedPinned(
    _ receipt: HistoryReceipt,
    id expectedID: HistoryItemID,
    position expectedPosition: UInt64,
    _ clause: String
) {
    guard case let .committed(commit) = receipt else {
        Issue.record("WS14 (\(clause)): expected a .committed receipt, got \(receipt)")
        return
    }
    #expect(
        commit.position.rawValue == expectedPosition,
        "WS14 (\(clause)): the placement advances Change Position exactly once"
    )
    guard case let .placedPinned(placedID) = commit.outcome else {
        Issue.record("WS14 (\(clause)): expected .placedPinned(id), got \(commit.outcome)")
        return
    }
    #expect(
        placedID == expectedID,
        "WS14 (\(clause)): the placed item is the placement target"
    )
}

/// Receipt-side assertion for one committed `.revise`: a `.committed` receipt
/// carrying `.revised(reference)` at exactly `expectedPosition`, naming the
/// revised item at the minted successor Content Version
/// (docs/05-authority-kernel.md §9 — the stamper mints
/// `currentVersion.successor()`; docs/02-domain.md §11 step 6). Returns the
/// minted reference so the scenario chains the next optimistic-concurrency
/// token from receipts rather than reconstructing versions by hand.
private static func revisedReference(
    from receipt: HistoryReceipt,
    id expectedID: HistoryItemID,
    version expectedVersion: UInt64,
    position expectedPosition: UInt64,
    _ clause: String
) -> HistoryItemReference? {
    guard case let .committed(commit) = receipt else {
        Issue.record("WS14 (\(clause)): expected a .committed receipt, got \(receipt)")
        return nil
    }
    #expect(
        commit.position.rawValue == expectedPosition,
        "WS14 (\(clause)): the revision advances Change Position exactly once"
    )
    guard case let .revised(reference) = commit.outcome else {
        Issue.record("WS14 (\(clause)): expected .revised(reference), got \(commit.outcome)")
        return nil
    }
    #expect(
        reference.id == expectedID,
        "WS14 (\(clause)): the revised reference names the target item"
    )
    #expect(
        reference.contentVersion.rawValue == expectedVersion,
        "WS14 (\(clause)): a byte-changing replace mints the successor Content Version"
    )
    return reference
}

/// WS14 (docs/06-cross-cutting.md §8): insert A, coalesce A, insert B and C,
/// pin all three and move C `.before` A, then replace A's Effective Content
/// twice; reopen the store and assert position, rows, revision lineage, pin
/// order, and Effective Content against the pre-restart receipts and
/// scenario values, and prove the rebuilt Signature Index complete by
/// coalescing a fresh capture of A's Canonical bytes into A. Every receipt's
/// Change Position is asserted against its scenario commit ordinal (1…10),
/// so the post-restart singleton comparison is against the proven
/// pre-restart commit count; observation times are fixed and monotone.
@Test func restartReconstructsDurableStateAndRebuildsCompleteSignatureIndex() async throws {
    let storeURL = WSSupport.tempStoreURL("ws14-restart-reconstruction")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Scenario constants: single-line plain text keeps the §15 projection
    // deterministic (title == body == text), and every capture carries one
    // observed source; observation times are fixed and monotone across the
    // whole scenario (docs/02-domain.md §3.1 fold rules).
    let textA = "ws14 alpha canonical text"
    let textB = "ws14 bravo canonical text"
    let textC = "ws14 charlie canonical text"
    let replacementOne = "ws14 alpha replacement one"
    let replacementTwo = "ws14 alpha replacement two"
    let plainText = "public.utf8-plain-text"
    let firstCopyA = Date(timeIntervalSinceReferenceDate: 700_040_100)
    let secondCopyA = Date(timeIntervalSinceReferenceDate: 700_040_200)
    let copyB = Date(timeIntervalSinceReferenceDate: 700_040_300)
    let copyC = Date(timeIntervalSinceReferenceDate: 700_040_400)
    let postRestartCopyA = Date(timeIntervalSinceReferenceDate: 700_040_500)
    let sourceA1 = "com.example.ws14.alpha.one"
    let sourceA2 = "com.example.ws14.alpha.two"
    let sourceB = "com.example.ws14.bravo"
    let sourceC = "com.example.ws14.charlie"
    let sourceA3 = "com.example.ws14.alpha.three"

    // ── Pre-restart scenario (commit ordinals 1–10). ──

    // Commit 1 — insert A (the WS1 path this gate builds on).
    let captureA = try await history.perform(.capture(
        WSSupport.textCapture(textA, observedAt: firstCopyA, source: sourceA1)
    ))
    guard case let .committed(commitA) = captureA,
          case let .inserted(referenceA) = commitA.outcome
    else {
        Issue.record("WS14 arrange: expected .committed(.inserted) for item A, got \(captureA)")
        return
    }
    #expect(
        commitA.position.rawValue == 1,
        "WS14 arrange: the insert commits at Change Position 1"
    )
    #expect(
        referenceA.contentVersion.rawValue == 1,
        "WS14 arrange: the inserted reference names the initial Content Version"
    )
    let idA = referenceA.id

    // Commit 2 — capture A again: Copy Coalescing folds the repeat
    // observation into A (docs/02-domain.md §13), preserving the winner's ID
    // and Content Version while the occurrence count moves to 2.
    let repeatA = try await history.perform(.capture(
        WSSupport.textCapture(textA, observedAt: secondCopyA, source: sourceA2)
    ))
    guard case let .committed(commitRepeatA) = repeatA,
          case let .coalesced(coalescedA) = commitRepeatA.outcome
    else {
        Issue.record("WS14 arrange: expected .committed(.coalesced) for the repeat of A, got \(repeatA)")
        return
    }
    #expect(
        commitRepeatA.position.rawValue == 2,
        "WS14 arrange: coalescing is a durable mutation and commits at Change Position 2"
    )
    #expect(
        coalescedA.id == idA,
        "WS14 arrange: the repeat capture coalesces into A"
    )
    #expect(
        coalescedA.contentVersion == referenceA.contentVersion,
        "WS14 arrange: coalescing preserves the winner's Content Version (docs/02-domain.md §13)"
    )

    // Commit 3 — insert B.
    let captureB = try await history.perform(.capture(
        WSSupport.textCapture(textB, observedAt: copyB, source: sourceB)
    ))
    guard case let .committed(commitB) = captureB,
          case let .inserted(referenceB) = commitB.outcome
    else {
        Issue.record("WS14 arrange: expected .committed(.inserted) for item B, got \(captureB)")
        return
    }
    #expect(
        commitB.position.rawValue == 3,
        "WS14 arrange: B's insert commits at Change Position 3"
    )
    #expect(
        referenceB.contentVersion.rawValue == 1,
        "WS14 arrange: B's inserted reference names the initial Content Version"
    )
    let idB = referenceB.id

    // Commit 4 — insert C.
    let captureC = try await history.perform(.capture(
        WSSupport.textCapture(textC, observedAt: copyC, source: sourceC)
    ))
    guard case let .committed(commitC) = captureC,
          case let .inserted(referenceC) = commitC.outcome
    else {
        Issue.record("WS14 arrange: expected .committed(.inserted) for item C, got \(captureC)")
        return
    }
    #expect(
        commitC.position.rawValue == 4,
        "WS14 arrange: C's insert commits at Change Position 4"
    )
    #expect(
        referenceC.contentVersion.rawValue == 1,
        "WS14 arrange: C's inserted reference names the initial Content Version"
    )
    let idC = referenceC.id

    // Commit 5 — pin A: a first pin with `.last` appends to the empty lane
    // (docs/02-domain.md §10 steps 2–3): A→0.
    let pinA = try await history.perform(.placePinned(idA, at: .last))
    Self.expectPlacedPinned(pinA, id: idA, position: 5, "pin A .last")

    // Commit 6 — pin B: B→1.
    let pinB = try await history.perform(.placePinned(idB, at: .last))
    Self.expectPlacedPinned(pinB, id: idB, position: 6, "pin B .last")

    // Commit 7 — pin C: C→2.
    let pinC = try await history.perform(.placePinned(idC, at: .last))
    Self.expectPlacedPinned(pinC, id: idC, position: 7, "pin C .last")

    // Commit 8 — move C `.before` A: [A, B, C] → [C, A, B]
    // (docs/02-domain.md §10 steps 2–4): C→0, A→1, B→2.
    let moveC = try await history.perform(.placePinned(idC, at: .before(idA)))
    Self.expectPlacedPinned(moveC, id: idC, position: 8, "move C .before(A)")

    // Commit 9 — first byte-changing revision of A: a `.replace` draft
    // carrying one explicit decision for the item's only Canonical type
    // (docs/03a-instruction-set.md §5), based on the receipt-captured current
    // version (optimistic concurrency, docs/02-domain.md §11 step 1).
    let reviseOne = try await history.perform(.revise(RevisionRequest(
        itemID: idA,
        expected: referenceA.contentVersion,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: plainText,
                action: .replace(bytes: Data(replacementOne.utf8))
            ),
        ]))
    )))
    guard let firstRevision = Self.revisedReference(
        from: reviseOne, id: idA, version: 2, position: 9, "revision 1 (replace)"
    ) else { return }

    // Commit 10 — second byte-changing revision of A, based on the first
    // revision's receipt token.
    let reviseTwo = try await history.perform(.revise(RevisionRequest(
        itemID: idA,
        expected: firstRevision.contentVersion,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: plainText,
                action: .replace(bytes: Data(replacementTwo.utf8))
            ),
        ]))
    )))
    guard let secondRevision = Self.revisedReference(
        from: reviseTwo, id: idA, version: 3, position: 10, "revision 2 (replace)"
    ) else { return }

    // The pre-restart commit count, proven one receipt position at a time
    // above: ten non-empty History Commits (docs/02-domain.md §13).
    let preRestartCommitCount: UInt64 = 10

    // ── RESTART: reopen the facade over the same on-disk store. The
    // docs/05-authority-kernel.md §13 startup (steps 5–9) rebuilds the
    // complete Signature Index from durable signature metadata WITHOUT
    // decoding content blobs and revalidates the full pinned ordinal set, so
    // a successful open re-proves both from durable state.
    let restartedHistory = try await WSSupport.openHistory(storeURL: storeURL)

    // ── Post-restart durable state and rebuilt-index proofs (WS14 i–iv)
    // live in WS14RestartDurableStateTests.swift: the verification body
    // moved verbatim into a static helper parameterized by the scenario
    // facts proven above (file-size split only).
    try await Self.assertRestartedDurableState(WS14ScenarioFacts(
        storeURL: storeURL,
        restartedHistory: restartedHistory,
        preRestartCommitCount: preRestartCommitCount,
        idA: idA,
        idB: idB,
        idC: idC,
        referenceB: referenceB,
        referenceC: referenceC,
        secondRevision: secondRevision,
        textA: textA,
        textB: textB,
        textC: textC,
        replacementOne: replacementOne,
        replacementTwo: replacementTwo,
        plainText: plainText,
        firstCopyA: firstCopyA,
        secondCopyA: secondCopyA,
        copyB: copyB,
        copyC: copyC,
        postRestartCopyA: postRestartCopyA,
        sourceA1: sourceA1,
        sourceA2: sourceA2,
        sourceB: sourceB,
        sourceC: sourceC,
        sourceA3: sourceA3
    ))
}
}
