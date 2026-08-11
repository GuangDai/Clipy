/// WS6 — Revision OCC and append-only revert (docs/06-cross-cutting.md §8
/// WS6): the commit/receipt/storage side of the two-phase revision path
/// (docs/05-authority-kernel.md §6.2) driven through the public
/// `SwiftDataHistory.perform(.revise(_:))` facade — a changing revision
/// commits once at the checked-successor Content Version, a stale draft is
/// rejected `.staleContent` with no commit, and a revert to Canonical
/// appends a NEW active revision while the old one stays byte-identical.
///
/// This file closes WS6's step-6 commit clauses; the separately landed
/// step-7 read suites own the "Effective-derived … paste updated" clause:
/// the `.committed` receipts with `.revised(reference)` at one successor
/// Content Version each (docs/02-domain.md §11, §13), the Change Position
/// advancing exactly once per commit (docs/02-domain.md §13), the
/// `.staleContent(expected:current:)` OCC rejection producing no commit, and
/// the durable append-only revision lineage plus the §15 Effective-derived
/// projection as seen through an INDEPENDENT second `ModelContainer` over
/// the same on-disk store (see `WSSupport`).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS6RevisionOCCTests {

/// A `.replace` draft request (docs/03a-instruction-set.md §5) substituting
/// `bytes` for the item's single `public.utf8-plain-text` representation,
/// based on the OCC token `expected`.
private static func replaceTextRequest(
    itemID: HistoryItemID,
    expected: ContentVersion,
    bytes: Data
) -> RevisionRequest {
    RevisionRequest(
        itemID: itemID,
        expected: expected,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: bytes)
            ),
        ]))
    )
}

/// WS6 (docs/06-cross-cutting.md §8): "Create an item, append a changing
/// revision, then submit a stale draft and expect `.staleContent` with no
/// commit. Revert from the current version to Canonical …; expect a new
/// Revision ID, old revisions unchanged, Effective-derived title/search/…
/// updated, and one successor Content Version." The revert append follows
/// docs/02-domain.md §2.5 rule 6 (a meaningful replace or revert appends a
/// new revision and makes it active) and the §14 D3 note (a
/// revert-to-canonical appends a real revision whose bytes happen to equal
/// Canonical — the active ID is never repointed); "one successor Content
/// Version" is §11's "a revert never restores an old version number" plus
/// the §13 `.appendRevision` stamping contract (checked successor, position
/// advances exactly once per commit).
@Test func changingRevisionStaleDraftAndAppendOnlyRevertAdvanceVersionAndPositionExactlyOnce() async throws {
    let storeURL = WSSupport.tempStoreURL("ws6-revision-occ")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // WS6: "Create an item" — one single-line raw text capture on an empty
    // store (single-line text keeps the §15 projection deterministic:
    // title == body == text, as in WS1).
    let canonicalText = "ws6 canonical text"
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_020_000)
    let source = "com.example.ws6"
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(canonicalText, observedAt: observedAt, source: source)
    ))
    guard case let .committed(captureCommit) = captureReceipt else {
        Issue.record("WS6: expected a .committed capture receipt, got \(captureReceipt)")
        return
    }
    // The first commit moves the singleton 0 → 1 (docs/05-authority-kernel.md
    // §3.2).
    #expect(captureCommit.position.rawValue == 1)
    guard case let .inserted(inserted) = captureCommit.outcome else {
        Issue.record("WS6: expected .inserted(reference), got \(captureCommit.outcome)")
        return
    }
    let itemID = inserted.id
    let version1 = inserted.contentVersion
    #expect(version1.rawValue == 1)

    // WS6: "append a changing revision" — replace the single Canonical type's
    // bytes, based on version 1 (the OCC token, docs/02-domain.md §11 step 1).
    let revisedText = "ws6 revised effective text"
    let reviseReceipt = try await history.perform(.revise(
        Self.replaceTextRequest(itemID: itemID, expected: version1, bytes: Data(revisedText.utf8))
    ))
    guard case let .committed(reviseCommit) = reviseReceipt else {
        Issue.record("WS6: expected a .committed revise receipt, got \(reviseReceipt)")
        return
    }
    // WS6: the revision is one History Commit — the Change Position advances
    // exactly once, 1 → 2 (docs/02-domain.md §13).
    #expect(reviseCommit.position.rawValue == 2)
    guard case let .revised(revised) = reviseCommit.outcome else {
        Issue.record("WS6: expected .revised(reference), got \(reviseCommit.outcome)")
        return
    }
    // WS6: "one successor Content Version" — `.appendRevision` stamps the
    // checked successor (docs/02-domain.md §13).
    #expect(revised.id == itemID)
    let version2 = revised.contentVersion
    #expect(version2.rawValue == 2)

    // Storage side, through the INDEPENDENT container (no production test
    // seam): one row at version 2, Canonical bytes untouched (revision never
    // changes Canonical Content, docs/02-domain.md §2.6), and exactly ONE
    // revision carrying the new Effective bytes as the active revision
    // (docs/02-domain.md §2.5 rules 1/6).
    let reviseContainer = try WSSupport.makeContainer(storeURL: storeURL)
    let reviseRows = try WSSupport.fetchRows(reviseContainer)
    #expect(reviseRows.count == 1)
    let reviseRow = try #require(reviseRows.first)
    #expect(reviseRow.id == itemID.rawValue)
    #expect(reviseRow.contentVersionRaw == 2)
    let reviseCanonical = try CanonicalBlobCodec.decode(reviseRow.canonicalBlob)
    #expect(reviseCanonical.representations.map(\.content.bytes) == [Data(canonicalText.utf8)])
    let reviseState = try RevisionStateBlobCodec.decode(
        reviseRow.revisionStateBlob,
        canonical: reviseCanonical
    )
    #expect(reviseState.revisions.count == 1)
    let firstRevision = try #require(reviseState.revisions.first)
    #expect(firstRevision.content.representations.map(\.typeIdentifier) == ["public.utf8-plain-text"])
    #expect(firstRevision.content.representations.map(\.bytes) == [Data(revisedText.utf8)])
    #expect(reviseState.activeRevisionID == firstRevision.id)
    // WS6: "Effective-derived title/search … updated" — the §15 durable
    // projection now derives from the revised Effective Content.
    #expect(reviseRow.title == revisedText)
    #expect(reviseRow.searchBody == revisedText)
    #expect(
        try EffectiveTypeIdentifiersBlobCodec.decode(reviseRow.effectiveTypeIdentifiersBlob)
            == ["public.utf8-plain-text"]
    )
    #expect(reviseRow.projectionSchemaVersion == 1)
    // The durable singleton matches the receipt's position (one transaction,
    // docs/06-cross-cutting.md §7.1).
    let revisePosition = try WSSupport.fetchPosition(reviseContainer)
    #expect(revisePosition.rawValue == 2)

    // WS6: "submit a stale draft and expect `.staleContent` with no commit" —
    // an otherwise real change (different bytes) based on the OLD version 1
    // while the item is at version 2. Phase one of the §6.2 two-phase path
    // rejects the stale OCC token before planning ever runs
    // (docs/05-authority-kernel.md §6.2).
    let staleRequest = Self.replaceTextRequest(
        itemID: itemID,
        expected: version1,
        bytes: Data("ws6 stale draft text".utf8)
    )
    await #expect(throws: HistoryFailure.staleContent(expected: version1, current: version2)) {
        try await history.perform(.revise(staleRequest))
    }

    // WS6: "with no commit" — the row, the lineage, the projection, and the
    // position singleton are exactly the post-revision state
    // (docs/02-domain.md §13: no commit, no advance; docs/04-coherence.md §4).
    let staleContainer = try WSSupport.makeContainer(storeURL: storeURL)
    let staleRows = try WSSupport.fetchRows(staleContainer)
    #expect(staleRows.count == 1)
    let staleRow = try #require(staleRows.first)
    #expect(staleRow.contentVersionRaw == 2)
    #expect(staleRow.title == revisedText)
    #expect(staleRow.searchBody == revisedText)
    let staleCanonical = try CanonicalBlobCodec.decode(staleRow.canonicalBlob)
    let staleState = try RevisionStateBlobCodec.decode(
        staleRow.revisionStateBlob,
        canonical: staleCanonical
    )
    #expect(staleState.revisions.map(\.id) == [firstRevision.id])
    #expect(staleState.activeRevisionID == firstRevision.id)
    let stalePosition = try WSSupport.fetchPosition(staleContainer)
    #expect(stalePosition.rawValue == 2)

    // WS6: "Revert from the current version to Canonical" — based on version
    // 2. §2.5 rule 6: a meaningful revert APPENDS a new revision and makes it
    // active; it never repoints the active ID (§14 D3 note) and never
    // restores an old version number (§11).
    let revertReceipt = try await history.perform(.revise(RevisionRequest(
        itemID: itemID,
        expected: version2,
        intent: .revert(to: .canonical)
    )))
    guard case let .committed(revertCommit) = revertReceipt else {
        Issue.record("WS6: expected a .committed revert receipt, got \(revertReceipt)")
        return
    }
    // Exactly one position advance for this commit, 2 → 3
    // (docs/02-domain.md §13).
    #expect(revertCommit.position.rawValue == 3)
    guard case let .revised(reverted) = revertCommit.outcome else {
        Issue.record("WS6: expected .revised(reference) for the revert, got \(revertCommit.outcome)")
        return
    }
    #expect(reverted.id == itemID)
    #expect(reverted.contentVersion.rawValue == 3)

    // Storage side: TWO revisions in append order (§2.5 rules 1/5) — the
    // first byte- and ID-identical to the pre-revert state, the second a NEW
    // Revision ID whose complete snapshot equals the Canonical bytes — and
    // the new revision is the active one.
    let revertContainer = try WSSupport.makeContainer(storeURL: storeURL)
    let revertRows = try WSSupport.fetchRows(revertContainer)
    #expect(revertRows.count == 1)
    let revertRow = try #require(revertRows.first)
    #expect(revertRow.contentVersionRaw == 3)
    let revertCanonical = try CanonicalBlobCodec.decode(revertRow.canonicalBlob)
    #expect(revertCanonical.representations.map(\.content.bytes) == [Data(canonicalText.utf8)])
    let revertState = try RevisionStateBlobCodec.decode(
        revertRow.revisionStateBlob,
        canonical: revertCanonical
    )
    #expect(revertState.revisions.count == 2)
    let preservedRevision = try #require(revertState.revisions.first)
    let appendedRevision = try #require(revertState.revisions.dropFirst().first)
    // WS6: "old revisions unchanged" (§2.5 rule 5: immutable, append-only).
    #expect(preservedRevision.id == firstRevision.id)
    #expect(preservedRevision.content.representations.map(\.bytes) == [Data(revisedText.utf8)])
    // WS6: "expect a new Revision ID" — appended, never repointed
    // (§2.5 rule 6; §14 D3 note).
    #expect(appendedRevision.id != firstRevision.id)
    #expect(appendedRevision.content.representations.map(\.typeIdentifier) == ["public.utf8-plain-text"])
    #expect(appendedRevision.content.representations.map(\.bytes) == [Data(canonicalText.utf8)])
    #expect(revertState.activeRevisionID == appendedRevision.id)
    // WS6: "Effective-derived title/search … updated" — the §15 projection is
    // back to the Canonical text.
    #expect(revertRow.title == canonicalText)
    #expect(revertRow.searchBody == canonicalText)
    #expect(
        try EffectiveTypeIdentifiersBlobCodec.decode(revertRow.effectiveTypeIdentifiersBlob)
            == ["public.utf8-plain-text"]
    )
    #expect(revertRow.projectionSchemaVersion == 1)
    // The durable singleton matches the revert receipt's position.
    let revertPosition = try WSSupport.fetchPosition(revertContainer)
    #expect(revertPosition.rawValue == 3)
}
}
