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
/// Phasing (docs/roadmap/README.md §3, WS-clause phasing note): WS14's
/// "match pre-restart public results" clause is a step-7 (reads +
/// observation) clause — `browse`/`details` still throw `StepDeferredError` —
/// and is NOT asserted here. This file closes the step-6 clauses, all seen
/// through an INDEPENDENT second `ModelContainer` over the same on-disk
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

    // ── Post-restart durable state, through the INDEPENDENT container. ──
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(
        rows.count == 3,
        "WS14 (rows): exactly the three captured items are retained"
    )
    let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    let rowA = try #require(rowsByID[idA.rawValue], "WS14 (rows): item A is retained")
    let rowB = try #require(rowsByID[idB.rawValue], "WS14 (rows): item B is retained")
    let rowC = try #require(rowsByID[idC.rawValue], "WS14 (rows): item C is retained")

    // WS14 (i): "current position" — the durable singleton equals the
    // pre-restart commit count; a restart creates no commit of its own.
    let position = try WSSupport.fetchPosition(container)
    #expect(
        position.rawValue == preRestartCommitCount,
        "WS14 (position): the durable singleton equals the pre-restart commit count"
    )

    // WS14 (ii): Content Versions match the receipt-captured pre-restart
    // values — A at the second revision's minted successor, B and C initial.
    #expect(
        rowA.contentVersionRaw == secondRevision.contentVersion.rawValue,
        "WS14 (versions): A's stored Content Version matches the pre-restart revision receipt"
    )
    #expect(
        rowB.contentVersionRaw == referenceB.contentVersion.rawValue,
        "WS14 (versions): B's stored Content Version matches the pre-restart insert receipt"
    )
    #expect(
        rowC.contentVersionRaw == referenceC.contentVersion.rawValue,
        "WS14 (versions): C's stored Content Version matches the pre-restart insert receipt"
    )

    // WS14 (ii): occurrence fields — A's coalesce fold (count 2, first/last
    // times and sources) and B/C's initial occurrences survive the restart
    // exactly (docs/05-authority-kernel.md §3.1, §9 occurrence folding).
    #expect(
        rowA.copyCount == 2,
        "WS14 (occurrences): A's repeat copy folded pre-restart"
    )
    #expect(
        rowA.firstCopiedAt == firstCopyA,
        "WS14 (occurrences): A's first copy time"
    )
    #expect(
        rowA.lastCopiedAt == secondCopyA,
        "WS14 (occurrences): A's last copy time"
    )
    #expect(
        rowA.firstSource == sourceA1,
        "WS14 (occurrences): A's first source"
    )
    #expect(
        rowA.lastSource == sourceA2,
        "WS14 (occurrences): A's last source"
    )
    #expect(
        rowB.copyCount == 1,
        "WS14 (occurrences): B was copied once"
    )
    #expect(
        rowB.firstCopiedAt == copyB,
        "WS14 (occurrences): B's first copy time"
    )
    #expect(
        rowB.lastCopiedAt == copyB,
        "WS14 (occurrences): B's last copy time"
    )
    #expect(
        rowB.firstSource == sourceB,
        "WS14 (occurrences): B's first source"
    )
    #expect(
        rowB.lastSource == sourceB,
        "WS14 (occurrences): B's last source"
    )
    #expect(
        rowC.copyCount == 1,
        "WS14 (occurrences): C was copied once"
    )
    #expect(
        rowC.firstCopiedAt == copyC,
        "WS14 (occurrences): C's first copy time"
    )
    #expect(
        rowC.lastCopiedAt == copyC,
        "WS14 (occurrences): C's last copy time"
    )
    #expect(
        rowC.firstSource == sourceC,
        "WS14 (occurrences): C's first source"
    )
    #expect(
        rowC.lastSource == sourceC,
        "WS14 (occurrences): C's last source"
    )

    // WS14 (ii): §15 projection fields — A's projection is of the SECOND
    // replacement (revision projection uses the prepared proposed Effective
    // Content, §15); B and C keep their capture-time projections; every row
    // carries the v1 projection schema version.
    let effectiveTypesA = try EffectiveTypeIdentifiersBlobCodec.decode(rowA.effectiveTypeIdentifiersBlob)
    let effectiveTypesB = try EffectiveTypeIdentifiersBlobCodec.decode(rowB.effectiveTypeIdentifiersBlob)
    let effectiveTypesC = try EffectiveTypeIdentifiersBlobCodec.decode(rowC.effectiveTypeIdentifiersBlob)
    #expect(
        rowA.projectionSchemaVersion == 1,
        "WS14 (projections): A's projection schema version is the v1 value"
    )
    #expect(
        rowA.title == replacementTwo,
        "WS14 (projections): A's title projects the active Effective Content"
    )
    #expect(
        rowA.searchBody == replacementTwo,
        "WS14 (projections): A's search body projects the active Effective Content"
    )
    #expect(
        effectiveTypesA == [plainText],
        "WS14 (projections): A's effective type identifiers"
    )
    #expect(
        rowB.projectionSchemaVersion == 1,
        "WS14 (projections): B's projection schema version is the v1 value"
    )
    #expect(
        rowB.title == textB,
        "WS14 (projections): B's title keeps the capture-time projection"
    )
    #expect(
        rowB.searchBody == textB,
        "WS14 (projections): B's search body keeps the capture-time projection"
    )
    #expect(
        effectiveTypesB == [plainText],
        "WS14 (projections): B's effective type identifiers"
    )
    #expect(
        rowC.projectionSchemaVersion == 1,
        "WS14 (projections): C's projection schema version is the v1 value"
    )
    #expect(
        rowC.title == textC,
        "WS14 (projections): C's title keeps the capture-time projection"
    )
    #expect(
        rowC.searchBody == textC,
        "WS14 (projections): C's search body keeps the capture-time projection"
    )
    #expect(
        effectiveTypesC == [plainText],
        "WS14 (projections): C's effective type identifiers"
    )

    // WS14 (ii): pin order — the [C, A, B] lane established pre-restart
    // (C→0, A→1, B→2) survives the restart, unique and exactly
    // `0 ..< pinnedCount` (D12; docs/02-domain.md §10).
    #expect(
        rowA.pinOrdinal == 1,
        "WS14 (pin order): A sits in the middle of the [C, A, B] lane"
    )
    #expect(
        rowB.pinOrdinal == 2,
        "WS14 (pin order): B is last in the [C, A, B] lane"
    )
    #expect(
        rowC.pinOrdinal == 0,
        "WS14 (pin order): C leads the [C, A, B] lane"
    )
    let storedOrdinals = rows.compactMap(\.pinOrdinal)
    #expect(
        Set(storedOrdinals).count == storedOrdinals.count,
        "WS14 (pin order): stored pin ordinals are unique (D12)"
    )
    #expect(
        Set(storedOrdinals) == Set(0 ..< storedOrdinals.count),
        "WS14 (pin order): stored pin ordinals are exactly 0 ..< pinnedCount (D12)"
    )

    // WS14 (iii): A's revision-state blob decodes (production codec,
    // docs/05-authority-kernel.md §4) to the FULL append-only list in mint
    // order — revisions are immutable and append-only in v1
    // (docs/02-domain.md §2.5 rule 5) — with the second revision active.
    // Canonical Content is untouched by the revisions (docs/02-domain.md D2).
    let canonicalA = try CanonicalBlobCodec.decode(rowA.canonicalBlob)
    #expect(
        canonicalA.representations.map(\.content.typeIdentifier) == [plainText],
        "WS14 (lineage): A's Canonical type survives revisions"
    )
    #expect(
        canonicalA.representations.map(\.content.bytes) == [Data(textA.utf8)],
        "WS14 (lineage): revisions never rewrite Canonical Content (docs/02-domain.md D2)"
    )
    let lineageA = try RevisionStateBlobCodec.decode(rowA.revisionStateBlob, canonical: canonicalA)
    #expect(
        lineageA.revisions.count == 2,
        "WS14 (lineage): the full append-only revision list survives the restart (docs/02-domain.md §2.5)"
    )
    let storedOne = try #require(
        lineageA.revisions.first,
        "WS14 (lineage): the first revision is retained"
    )
    let storedTwo = try #require(
        lineageA.revisions.last,
        "WS14 (lineage): the second revision is retained"
    )
    #expect(
        storedOne.id != storedTwo.id,
        "WS14 (lineage): revision IDs are unique within the item (docs/02-domain.md §2.5 rule 2)"
    )
    #expect(
        storedOne.createdAt <= storedTwo.createdAt,
        "WS14 (lineage): the revision list is ordered by append order (docs/02-domain.md §2.5 rule 1)"
    )
    #expect(
        lineageA.activeRevisionID == storedTwo.id,
        "WS14 (lineage): the active Revision ID names the second revision"
    )
    #expect(
        storedOne.content.representations.map(\.typeIdentifier) == [plainText],
        "WS14 (lineage): the first revision's type identifiers"
    )
    #expect(
        storedOne.content.representations.map(\.bytes) == [Data(replacementOne.utf8)],
        "WS14 (lineage): the first revision's complete snapshot is independently readable (§2.5)"
    )
    #expect(
        storedTwo.content.representations.map(\.typeIdentifier) == [plainText],
        "WS14 (lineage): the second revision's type identifiers"
    )

    // WS14 (iii): Effective Content derivation (docs/02-domain.md §2.6) —
    // with an active revision, Effective Content is that revision's complete
    // content snapshot; the active revision alone contains every byte
    // required to rebuild current Effective Content after restart (§4).
    let activeRevision = try #require(
        lineageA.revisions.first(where: { $0.id == lineageA.activeRevisionID }),
        "WS14 (effective content): the active ID names exactly one stored revision (D3)"
    )
    #expect(
        activeRevision.content.representations.map(\.bytes) == [Data(replacementTwo.utf8)],
        "WS14 (effective content): the active revision's bytes are the current Effective Content (docs/02-domain.md §2.6)"
    )

    // WS14 (iii): B and C are Canonical-state items (D3) — empty revision
    // list, nil active ID — so their Effective Content is the Canonical
    // content with fingerprints stripped (docs/02-domain.md §2.6).
    let canonicalB = try CanonicalBlobCodec.decode(rowB.canonicalBlob)
    let lineageB = try RevisionStateBlobCodec.decode(rowB.revisionStateBlob, canonical: canonicalB)
    #expect(
        lineageB.revisions.isEmpty,
        "WS14 (lineage): B has no revisions (D3)"
    )
    #expect(
        lineageB.activeRevisionID == nil,
        "WS14 (lineage): B's active Revision ID is nil (D3)"
    )
    #expect(
        canonicalB.representations.map(\.content.bytes) == [Data(textB.utf8)],
        "WS14 (effective content): B's Effective Content is its Canonical bytes (docs/02-domain.md §2.6)"
    )
    let canonicalC = try CanonicalBlobCodec.decode(rowC.canonicalBlob)
    let lineageC = try RevisionStateBlobCodec.decode(rowC.revisionStateBlob, canonical: canonicalC)
    #expect(
        lineageC.revisions.isEmpty,
        "WS14 (lineage): C has no revisions (D3)"
    )
    #expect(
        lineageC.activeRevisionID == nil,
        "WS14 (lineage): C's active Revision ID is nil (D3)"
    )
    #expect(
        canonicalC.representations.map(\.content.bytes) == [Data(textC.utf8)],
        "WS14 (effective content): C's Effective Content is its Canonical bytes (docs/02-domain.md §2.6)"
    )

    // ── WS14 (iv): the rebuilt Signature Index is COMPLETE. A post-restart
    // capture of A's CANONICAL bytes (never rewritten by the revisions,
    // §2.6) must coalesce into A — candidacy re-proven from durable
    // signature metadata at startup (§13) — not insert a duplicate row.
    let probeReceipt = try await restartedHistory.perform(.capture(
        WSSupport.textCapture(textA, observedAt: postRestartCopyA, source: sourceA3)
    ))
    guard case let .committed(probeCommit) = probeReceipt,
          case let .coalesced(probeReference) = probeCommit.outcome
    else {
        Issue.record("WS14 (rebuilt index): expected .committed(.coalesced) for A's Canonical bytes post-restart, got \(probeReceipt)")
        return
    }
    #expect(
        probeCommit.position.rawValue == preRestartCommitCount + 1,
        "WS14 (rebuilt index): the coalesce is the next History Commit after the pre-restart count"
    )
    #expect(
        probeReference.id == idA,
        "WS14 (rebuilt index): the post-restart capture coalesces into A — no duplicate item"
    )
    #expect(
        probeReference.contentVersion == secondRevision.contentVersion,
        "WS14 (rebuilt index): coalescing preserves the winner's current Content Version (docs/02-domain.md §13)"
    )

    // WS14 (iv), durable side: still exactly three rows; A's occurrence fold
    // advanced (count 3, new last time/source, first observation untouched),
    // Content Version preserved (docs/02-domain.md D2), and the singleton
    // moved exactly once.
    let verification = try WSSupport.makeContainer(storeURL: storeURL)
    let verifiedRows = try WSSupport.fetchRows(verification)
    #expect(
        verifiedRows.count == 3,
        "WS14 (rebuilt index): no duplicate row — the index mapped A's Canonical signature to A"
    )
    let verifiedRowsByID = Dictionary(uniqueKeysWithValues: verifiedRows.map { ($0.id, $0) })
    let verifiedRowA = try #require(
        verifiedRowsByID[idA.rawValue],
        "WS14 (rebuilt index): item A is retained"
    )
    #expect(
        verifiedRowA.copyCount == 3,
        "WS14 (rebuilt index): the post-restart copy folded into A"
    )
    #expect(
        verifiedRowA.firstCopiedAt == firstCopyA,
        "WS14 (rebuilt index): A's first copy time is untouched"
    )
    #expect(
        verifiedRowA.lastCopiedAt == postRestartCopyA,
        "WS14 (rebuilt index): A's last copy time advanced"
    )
    #expect(
        verifiedRowA.firstSource == sourceA1,
        "WS14 (rebuilt index): A's first source is untouched"
    )
    #expect(
        verifiedRowA.lastSource == sourceA3,
        "WS14 (rebuilt index): A's last source advanced"
    )
    #expect(
        verifiedRowA.contentVersionRaw == secondRevision.contentVersion.rawValue,
        "WS14 (rebuilt index): A's Content Version is untouched by coalescing"
    )
    let verifiedPosition = try WSSupport.fetchPosition(verification)
    #expect(
        verifiedPosition.rawValue == preRestartCommitCount + 1,
        "WS14 (rebuilt index): the durable singleton matches the probe receipt"
    )
}
}
