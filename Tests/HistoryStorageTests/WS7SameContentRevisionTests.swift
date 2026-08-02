/// WS7 — Same-content revision no-op (docs/06-cross-cutting.md §8 WS7): the
/// commit/receipt/storage side of submitting a replace or revert whose
/// proposed Effective Content equals the item's current bytes through the
/// public `SwiftDataHistory.perform(.revise(_:))` and the real two-phase
/// OCC-safe revision path (docs/05-authority-kernel.md §6.2, §9) whose Domain
/// planning turns a byte-equal proposal into `.unchanged` (docs/02-domain.md
/// §2.5 rule 7, §11 step 5).
///
/// Phasing (docs/roadmap/README.md §3, WS-clause phasing note): WS7's
/// no-observation-emission clause is a step-7 (reads + observation) clause
/// and is NOT asserted here; this file closes the step-6 clauses — the
/// `.unchanged` receipt (docs/03a-instruction-set.md §6: no position, no
/// invalidation, not a History Commit), no appended revision, and no Content
/// Version / Change Position advance (docs/02-domain.md §13 `.unchanged` row:
/// preserve, no commit, no advance) — with the durable row/singleton state
/// seen through an INDEPENDENT second `ModelContainer` over the same on-disk
/// store (see `WSSupport`).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS7SameContentRevisionTests {

/// Decodes one retained row's revision lineage through the production
/// codecs: the Canonical blob first (it supplies the Canonical type set for
/// the §4 containment check), then the revision-state blob with the full §4
/// check set (docs/05-authority-kernel.md §4).
private static func decodeLineage(
    of row: HistoryItemRow
) throws -> (revisions: [ContentRevision], activeRevisionID: RevisionID?) {
    let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
    return try RevisionStateBlobCodec.decode(row.revisionStateBlob, canonical: canonical)
}

/// WS7 scenario A (docs/06-cross-cutting.md §8): a `.replace` draft whose
/// single `.inheritCanonical` decision proposes exactly the current
/// Effective bytes of a Canonical-state item is a no-op — `.unchanged`
/// receipt, the revision lineage stays empty, and neither `contentVersionRaw`
/// nor the position singleton moves.
@Test func replaceInheritingCanonicalBytesIsUnchangedAndAppendsNothing() async throws {
    let storeURL = WSSupport.tempStoreURL("ws7-replace-inherit-noop")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Setup: one normalized raw text capture — Content Version 1, Change
    // Position 1, Canonical-state lineage (§8 WS1). Single-line text keeps
    // the §15 projection deterministic.
    let text = "ws7 replace no-op target"
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_020_000)
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: observedAt, source: "com.example.ws7.a")
    ))
    guard case let .committed(captureCommit) = captureReceipt,
          case let .inserted(reference) = captureCommit.outcome else {
        Issue.record("WS7(A) setup: expected .committed with .inserted(reference), got \(captureReceipt)")
        return
    }
    #expect(captureCommit.position.rawValue == 1)
    #expect(reference.contentVersion.rawValue == 1)

    // Act: a replace draft whose only decision carries the Canonical
    // representation into Effective unchanged — the proposal is byte-equal
    // to the current Effective Content (the §2.6 no-active-revision
    // derivation), so §11 step 5 turns it into a no-op.
    let receipt = try await history.perform(.revise(RevisionRequest(
        itemID: reference.id,
        expected: ContentVersion(rawValue: 1),
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .inheritCanonical
            ),
        ]))
    )))

    // WS7: "Expect `.unchanged`" — no History Commit, no position, no
    // invalidation (docs/03a-instruction-set.md §6).
    guard case .unchanged = receipt else {
        Issue.record("WS7(A): expected a .unchanged receipt, got \(receipt)")
        return
    }

    // Storage side, through the INDEPENDENT container: still exactly one row.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == reference.id.rawValue)

    // WS7: "no appended revision" — the lineage is still the empty
    // Canonical-state list with a nil active Revision ID (D3).
    let lineage = try Self.decodeLineage(of: row)
    #expect(lineage.revisions.isEmpty)
    #expect(lineage.activeRevisionID == nil)

    // WS7: "no Content Version … advance" (docs/02-domain.md §13 `.unchanged`
    // row: preserve).
    #expect(row.contentVersionRaw == 1)

    // WS7: "no … Change Position advance" (§13: no commit, no advance) — the
    // durable singleton still holds the capture commit's position.
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 1)
}

/// WS7 scenario B (docs/06-cross-cutting.md §8): a `.revert(to: .canonical)`
/// on a Canonical-state item proposes exactly the current Effective bytes and
/// is likewise a no-op — `.unchanged` receipt, empty lineage, and neither
/// token advances. (A revert-to-canonical after real revisions DOES append —
/// §2.5 rule 6 and D3's iff are about the revision list; that changing case
/// is WS6's, not this no-op file's.)
@Test func revertToCanonicalOnCanonicalStateItemIsUnchangedAndAppendsNothing() async throws {
    let storeURL = WSSupport.tempStoreURL("ws7-revert-canonical-noop")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Setup: one normalized raw text capture — Content Version 1, Change
    // Position 1, Canonical-state lineage.
    let text = "ws7 revert no-op target"
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_021_000)
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: observedAt, source: "com.example.ws7.b")
    ))
    guard case let .committed(captureCommit) = captureReceipt,
          case let .inserted(reference) = captureCommit.outcome else {
        Issue.record("WS7(B) setup: expected .committed with .inserted(reference), got \(captureReceipt)")
        return
    }
    #expect(captureCommit.position.rawValue == 1)
    #expect(reference.contentVersion.rawValue == 1)

    // Act: revert to Canonical on an item whose Effective Content already
    // equals Canonical — preparation resolves the target to the Canonical
    // bytes (05 §6.2), and §11 step 5 turns the byte-equal proposal into a
    // no-op.
    let receipt = try await history.perform(.revise(RevisionRequest(
        itemID: reference.id,
        expected: ContentVersion(rawValue: 1),
        intent: .revert(to: .canonical)
    )))

    // WS7: "Expect `.unchanged`".
    guard case .unchanged = receipt else {
        Issue.record("WS7(B): expected a .unchanged receipt, got \(receipt)")
        return
    }

    // Storage side, through the INDEPENDENT container: still exactly one row.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == reference.id.rawValue)

    // WS7: "no appended revision" — the lineage is still the empty
    // Canonical-state list with a nil active Revision ID (D3).
    let lineage = try Self.decodeLineage(of: row)
    #expect(lineage.revisions.isEmpty)
    #expect(lineage.activeRevisionID == nil)

    // WS7: "no Content Version … advance" (docs/02-domain.md §13).
    #expect(row.contentVersionRaw == 1)

    // WS7: "no … Change Position advance" (§13).
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 1)
}

/// WS7 scenario C (docs/06-cross-cutting.md §8): after a byte-changing
/// replace commits (Content Version 2, one stored revision, Change
/// Position 2), a second `.replace` proposing exactly those now-current bytes
/// at `expected: 2` is again a no-op — `.unchanged`, the one revision remains
/// the only one, and neither token advances.
@Test func replaceProposingCurrentRevisionBytesIsUnchangedAndKeepsOneRevision() async throws {
    let storeURL = WSSupport.tempStoreURL("ws7-replace-after-revision-noop")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Setup: one normalized raw text capture — Content Version 1, Change
    // Position 1.
    let text = "ws7 revision no-op target"
    let replacementText = "ws7 replacement bytes"
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_022_000)
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: observedAt, source: "com.example.ws7.c")
    ))
    guard case let .committed(captureCommit) = captureReceipt,
          case let .inserted(reference) = captureCommit.outcome else {
        Issue.record("WS7(C) setup: expected .committed with .inserted(reference), got \(captureReceipt)")
        return
    }
    #expect(captureCommit.position.rawValue == 1)
    #expect(reference.contentVersion.rawValue == 1)

    // Setup: a real byte-changing replace (§2.5 rule 6) — one revision is
    // appended and made active, Content Version advances to 2, and the commit
    // advances the position once (§13 `.appendRevision` row).
    let replaceReceipt = try await history.perform(.revise(RevisionRequest(
        itemID: reference.id,
        expected: ContentVersion(rawValue: 1),
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: Data(replacementText.utf8))
            ),
        ]))
    )))
    guard case let .committed(replaceCommit) = replaceReceipt else {
        Issue.record("WS7(C) setup: expected .committed for the byte-changing replace, got \(replaceReceipt)")
        return
    }
    #expect(replaceCommit.position.rawValue == 2)
    guard case let .revised(revisedReference) = replaceCommit.outcome else {
        Issue.record("WS7(C) setup: expected .revised(reference), got \(replaceCommit.outcome)")
        return
    }
    #expect(revisedReference.id == reference.id)
    #expect(revisedReference.contentVersion.rawValue == 2)

    // Act: a second replace proposing exactly the CURRENT bytes at
    // `expected: 2` — §11 step 5 turns the byte-equal proposal into a no-op.
    let receipt = try await history.perform(.revise(RevisionRequest(
        itemID: reference.id,
        expected: ContentVersion(rawValue: 2),
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: Data(replacementText.utf8))
            ),
        ]))
    )))

    // WS7: "Expect `.unchanged`".
    guard case .unchanged = receipt else {
        Issue.record("WS7(C): expected a .unchanged receipt, got \(receipt)")
        return
    }

    // Storage side, through the INDEPENDENT container: still exactly one row.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == reference.id.rawValue)

    // WS7: "no appended revision" — exactly the one revision the
    // byte-changing replace appended: it stores the replacement bytes and is
    // still the active revision (§2.5 rules 5–6; D4 append-only).
    let lineage = try Self.decodeLineage(of: row)
    #expect(lineage.revisions.count == 1)
    let revision = try #require(lineage.revisions.first)
    #expect(revision.content.representations.map(\.typeIdentifier) == ["public.utf8-plain-text"])
    #expect(revision.content.representations.map(\.bytes) == [Data(replacementText.utf8)])
    let activeRevisionID = try #require(lineage.activeRevisionID)
    #expect(activeRevisionID == revision.id)

    // WS7: "no Content Version … advance" (docs/02-domain.md §13) — the row
    // still holds the successor version the real revision minted.
    #expect(row.contentVersionRaw == 2)

    // WS7: "no … Change Position advance" (§13) — the durable singleton still
    // holds the byte-changing replace's commit position.
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 2)
}
}
