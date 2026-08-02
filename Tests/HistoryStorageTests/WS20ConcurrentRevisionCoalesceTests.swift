/// WS20 — Concurrent revision and coalescing (docs/06-cross-cutting.md §8
/// WS20): the OCC-safe two-phase revision interleavings of
/// docs/05-authority-kernel.md §6.2, driven deterministically by the
/// `SuspensionGate` concurrency harness (Tests/HistoryStorageTests/
/// ConcurrencyHarness/ConcurrencyHarness.swift) over the roadmap-owned
/// Authority suspension seam (`AuthoritySuspensionPoint.revisionCommitEntry`).
///
/// Storage-side proof, not a public-facade path (the same stance as WS5 and
/// WS13): the suspension seam is Authority-internal, so both tests drive a
/// directly constructed Authority (`WSSupport.makeAuthority`), the real
/// `IngestPreparationActor` for capture preparation, and the real
/// `RevisionPreparationActor` for the off-Authority phase of every revision
/// (`revisionPreparationSnapshot(_:)` → `prepare(_:from:)` →
/// `commitRevision(_:_:)`, 05 §6.2). Row-level assertions go through the
/// INDEPENDENT second `ModelContainer` over the same on-disk store (see
/// `WSSupport`), decoded with the production `CanonicalBlobCodec` /
/// `RevisionStateBlobCodec`.
///
/// Handler wiring note: the seam handler fires for BOTH commit entry points,
/// and in the second scenario the interference enters the SAME
/// `.revisionCommitEntry` point as the parked operation — an unconditional
/// `park(at:)` would either strand the capture interference at
/// `.captureCommitEntry` with nothing to resume it (first scenario) or trip
/// `SuspensionGate`'s one-parked-task-per-point precondition (second
/// scenario). The handler therefore parks only at `.revisionCommitEntry` and
/// only for the FIRST arrival (`FirstParkLatch` below); the harness-driven
/// interference passes through.
///
/// Deferral (docs/roadmap/README.md §3 WS-clause phasing note): NONE. WS20
/// names no public-read or observation clause — both clauses are
/// commit/storage-side and are closed here: (a) a Copy Coalescing commit
/// between the two phases of a revision leaves the revision committable
/// (Content Version preserved, 02 §13) with the occurrence folded, and (b) a
/// content-changing revision between the phases of a first revision makes
/// the first return `.staleContent` (02 §11 step 1).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS20ConcurrentRevisionCoalesceTests {

/// One-shot arming flag for the WS20 suspension handler (see the file
/// header): only the FIRST commit to reach the guarded point parks; the
/// harness-driven interference passes through. `SuspensionGate.park(at:)`
/// forbids two tasks parked at one named point.
private actor FirstParkLatch {
    private var armed = true

    /// Returns `true` exactly once — to the first caller — then stays
    /// disarmed for every later arrival.
    func consume() -> Bool {
        defer { armed = false }
        return armed
    }
}

/// Installs the WS20 suspension handler (file header): park at
/// `.revisionCommitEntry`, once only, on the test-owned gate.
private static func installRevisionEntryPark(
    on authority: HistoryAuthority,
    gate: SuspensionGate,
    latch: FirstParkLatch
) async {
    await authority.setSuspensionHandler { point in
        guard point == .revisionCommitEntry else { return }
        let first = await latch.consume()
        guard first else { return }
        await gate.park(at: point.rawValue)
    }
}

/// A byte-changing `.replace` revision request for the single
/// public.utf8-plain-text representation these scenarios use, OCC-tokened at
/// `expected` (docs/03a-instruction-set.md §5: exactly one explicit decision
/// for every Canonical type).
private static func replaceRequest(
    itemID: HistoryItemID,
    expected: ContentVersion,
    text: String
) -> RevisionRequest {
    RevisionRequest(
        itemID: itemID,
        expected: expected,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: Data(text.utf8))
            ),
        ]))
    )
}

/// WS20 (docs/06-cross-cutting.md §8): "Between the two phases of a revision,
/// perform a Copy Coalescing commit on the same item; assert the revision
/// still commits (Content Version preserved) and occurrence is folded." The
/// coalescing commit preserves the item's Content Version (02 §13; 05 §6.2:
/// "A pin or Copy Coalescing commit between the two phases preserves Content
/// Version and content lineage, so the proposal remains valid"), so the
/// parked revision's second fact load still satisfies the OCC recheck and
/// the revision commits at the next version.
@Test func copyCoalescingBetweenRevisionPhasesStillCommitsRevisionWithFoldedOccurrence() async throws {
    let storeURL = WSSupport.tempStoreURL("ws20-revision-coalesce")
    defer { WSSupport.removeStore(storeURL) }
    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)
    let ingest = IngestPreparationActor()
    let revisionPreparation = RevisionPreparationActor()

    // Arrange: text X inserted on an empty store — position 1, Content
    // Version 1 (the WS1 path this gate builds on).
    let originalText = "ws20 coalesce original"
    let originalObservedAt = Date(timeIntervalSinceReferenceDate: 700_020_000)
    let originalSource = "com.example.ws20.coalesce.first"
    let insertBundle = try await ingest.prepare(
        WSSupport.textCapture(originalText, observedAt: originalObservedAt, source: originalSource)
    )
    let insertReceipt = try await authority.commitCapture(insertBundle)
    guard case let .committed(insertCommit) = insertReceipt else {
        Issue.record("WS20 arrange: expected a .committed receipt for the setup capture, got \(insertReceipt)")
        return
    }
    guard case let .inserted(insertedReference) = insertCommit.outcome else {
        Issue.record("WS20 arrange: expected .inserted(reference), got \(insertCommit.outcome)")
        return
    }
    #expect(insertCommit.position.rawValue == 1)
    #expect(insertedReference.contentVersion.rawValue == 1)

    // Phase one of the §6.2 two-phase revision (replace X's bytes with Y's):
    // the Authority captures the Sendable snapshot (the OCC token is current,
    // so nothing is rejected) and the proposal is resolved, validated, and
    // projected off the Authority. Nothing is committed yet.
    let revisedText = "ws20 coalesce revised"
    let request = Self.replaceRequest(
        itemID: insertedReference.id,
        expected: insertedReference.contentVersion,
        text: revisedText
    )
    let snapshot = try await authority.revisionPreparationSnapshot(request)
    let bundle = try await revisionPreparation.prepare(request, from: snapshot)

    // The interference bundle: the SAME canonical text X re-captured while
    // the revision is between phases — Copy Coalescing folds the occurrence
    // into the same item and preserves its Content Version (02 §13, D2).
    let coalesceObservedAt = Date(timeIntervalSinceReferenceDate: 700_020_500)
    let coalesceSource = "com.example.ws20.coalesce.second"
    let coalesceBundle = try await ingest.prepare(
        WSSupport.textCapture(originalText, observedAt: coalesceObservedAt, source: coalesceSource)
    )

    // Drive the exact 06 §8 WS20 interleaving: the revision commit parks at
    // its Authority-entry seam (before any context exists, 05 §5), the
    // coalescing capture commits in between, then the revision resumes into
    // its second fact load and the OCC recheck (05 §6.2, 02 §11).
    let gate = SuspensionGate()
    let latch = FirstParkLatch()
    await Self.installRevisionEntryPark(on: authority, gate: gate, latch: latch)
    let results = try await gate.runParked(
        at: AuthoritySuspensionPoint.revisionCommitEntry.rawValue,
        operation: { try await authority.commitRevision(request, bundle) },
        whileCommitting: { try await authority.commitCapture(coalesceBundle) }
    )

    // WS20: "the revision still commits" — `.revised` at the next Content
    // Version: the interference preserved the item's version, so the OCC
    // recheck still passed (05 §6.2).
    guard case let .committed(revisionCommit) = results.paused else {
        Issue.record("WS20: expected a .committed receipt for the parked revision, got \(results.paused)")
        return
    }
    guard case let .revised(revisedReference) = revisionCommit.outcome else {
        Issue.record("WS20: expected .revised(reference), got \(revisionCommit.outcome)")
        return
    }
    #expect(revisedReference.id == insertedReference.id)
    #expect(revisedReference.contentVersion.rawValue == 2)

    // WS20: "a Copy Coalescing commit on the same item" — `.coalesced` naming
    // the same item at the PRESERVED Content Version (02 §13: the receipt
    // reference names the winner's loaded version, 05 §9).
    guard case let .committed(coalesceCommit) = results.interfering else {
        Issue.record("WS20: expected a .committed receipt for the interfering capture, got \(results.interfering)")
        return
    }
    guard case let .coalesced(coalescedReference) = coalesceCommit.outcome else {
        Issue.record("WS20: expected .coalesced(reference), got \(coalesceCommit.outcome)")
        return
    }
    #expect(coalescedReference.id == insertedReference.id)
    #expect(coalescedReference.contentVersion.rawValue == 1)

    // Three History Commits total — insert, coalesce, revision — so the two
    // interleaved receipts carry positions 2 and 3 between them (the harness
    // fixes the order; WS20's clause is the total, 06 §8).
    #expect([coalesceCommit.position.rawValue, revisionCommit.position.rawValue].sorted() == [2, 3])

    // Storage side, through the INDEPENDENT container: one row carrying BOTH
    // the folded occurrence and the committed revision (06 §8 WS20).
    let verification = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(verification)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == insertedReference.id.rawValue)
    // WS20: "Content Version preserved" then advanced — the coalesce kept
    // version 1 (02 §13); the resumed revision moved the row to 2.
    #expect(row.contentVersionRaw == 2)
    // WS20: "occurrence is folded" — count 2, first observation untouched,
    // monotone last-copied time, the new last source (05 §9 occurrence
    // folding; the WS2 fold asserted through the same columns).
    #expect(row.copyCount == 2)
    #expect(row.firstCopiedAt == originalObservedAt)
    #expect(row.lastCopiedAt == coalesceObservedAt)
    #expect(row.firstSource == originalSource)
    #expect(row.lastSource == coalesceSource)

    // Canonical Content is preserved byte-exactly by both commits (02 D2);
    // the lineage holds exactly one revision — the resumed one — active and
    // carrying the revised bytes (05 §4, §10 `.appendRevision`).
    let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
    #expect(canonical.representations.map(\.content.bytes) == [Data(originalText.utf8)])
    let lineage = try RevisionStateBlobCodec.decode(row.revisionStateBlob, canonical: canonical)
    #expect(lineage.revisions.count == 1)
    #expect(lineage.activeRevisionID == bundle.domain.candidateRevisionID)
    let activeRevision = try #require(lineage.revisions.first)
    #expect(activeRevision.content.representations.map(\.bytes) == [Data(revisedText.utf8)])
    // The §15 durable projection was restamped from the revised Effective
    // Content (single-line text: title == body == text, as in WS1).
    #expect(row.title == revisedText)
    #expect(row.searchBody == revisedText)

    // WS20: the durable singleton matches the three commits (06 §7.1: one
    // transaction per History Commit).
    let position = try WSSupport.fetchPosition(verification)
    #expect(position.rawValue == 3)
}

/// WS20 (docs/06-cross-cutting.md §8): "Perform instead a content-changing
/// revision between the phases of a first revision; assert the first returns
/// `.staleContent`." The interleaved second revision advances the item's
/// Content Version (05 §6.2: "A content-changing revision advances Content
/// Version and causes the second OCC check to reject the prepared
/// proposal"), so when the parked first revision resumes, the Domain OCC
/// recheck (02 §11 step 1) throws `.staleContent(expected: 1, current: 2)`
/// and nothing of the first revision commits (05 §10).
@Test func contentChangingRevisionBetweenPhasesFailsTheFirstRevisionStale() async throws {
    let storeURL = WSSupport.tempStoreURL("ws20-revision-stale")
    defer { WSSupport.removeStore(storeURL) }
    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)
    let ingest = IngestPreparationActor()
    let revisionPreparation = RevisionPreparationActor()

    // Arrange: text X inserted on an empty store — position 1, version 1.
    let originalText = "ws20 stale original"
    let originalObservedAt = Date(timeIntervalSinceReferenceDate: 700_021_000)
    let originalSource = "com.example.ws20.stale.first"
    let insertBundle = try await ingest.prepare(
        WSSupport.textCapture(originalText, observedAt: originalObservedAt, source: originalSource)
    )
    let insertReceipt = try await authority.commitCapture(insertBundle)
    guard case let .committed(insertCommit) = insertReceipt else {
        Issue.record("WS20 arrange: expected a .committed receipt for the setup capture, got \(insertReceipt)")
        return
    }
    guard case let .inserted(insertedReference) = insertCommit.outcome else {
        Issue.record("WS20 arrange: expected .inserted(reference), got \(insertCommit.outcome)")
        return
    }
    #expect(insertCommit.position.rawValue == 1)
    #expect(insertedReference.contentVersion.rawValue == 1)

    // TWO content-changing revisions, each put through §6.2 phase one at the
    // SAME base version 1 and proposing DIFFERENT bytes (both preparations
    // are valid: phase one found the OCC token current for each).
    let firstRevisedText = "ws20 stale first revision"
    let secondRevisedText = "ws20 stale second revision"
    let firstRequest = Self.replaceRequest(
        itemID: insertedReference.id,
        expected: insertedReference.contentVersion,
        text: firstRevisedText
    )
    let secondRequest = Self.replaceRequest(
        itemID: insertedReference.id,
        expected: insertedReference.contentVersion,
        text: secondRevisedText
    )
    let firstSnapshot = try await authority.revisionPreparationSnapshot(firstRequest)
    let firstBundle = try await revisionPreparation.prepare(firstRequest, from: firstSnapshot)
    let secondSnapshot = try await authority.revisionPreparationSnapshot(secondRequest)
    let secondBundle = try await revisionPreparation.prepare(secondRequest, from: secondSnapshot)

    // Drive the interleaving: the FIRST revision parks at its commit-entry
    // seam; the SECOND revision (based on the same version) commits in
    // between, advancing the item to version 2; the first resumes into the
    // OCC recheck and loses. `runParked` rethrows the parked operation's
    // failure (after resuming/cancelling so no task is left parked), so the
    // exact typed failure is caught and asserted here.
    let gate = SuspensionGate()
    let latch = FirstParkLatch()
    await Self.installRevisionEntryPark(on: authority, gate: gate, latch: latch)
    do {
        _ = try await gate.runParked(
            at: AuthoritySuspensionPoint.revisionCommitEntry.rawValue,
            operation: { try await authority.commitRevision(firstRequest, firstBundle) },
            whileCommitting: { try await authority.commitRevision(secondRequest, secondBundle) }
        )
        Issue.record("WS20: expected the parked first revision to throw .staleContent, but it committed")
    } catch let failure as HistoryFailure {
        // WS20: "the first returns `.staleContent`" (06 §8) — the request's
        // base version 1 against the interleaved commit's version 2 (02 §11
        // step 1, 05 §16 mapping).
        #expect(failure == HistoryFailure.staleContent(
            expected: insertedReference.contentVersion,
            current: ContentVersion(rawValue: 2)
        ))
    } catch {
        Issue.record("WS20: expected HistoryFailure.staleContent, got \(error)")
    }

    // Storage side, through the INDEPENDENT container: exactly ONE item, at
    // version 2, with the SECOND revision's bytes active — the stale first
    // revision appended nothing and advanced nothing (05 §10: closure
    // failure — here the pre-transaction OCC rejection — commits nothing).
    let verification = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(verification)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == insertedReference.id.rawValue)
    #expect(row.contentVersionRaw == 2)
    #expect(row.copyCount == 1)
    #expect(row.firstCopiedAt == originalObservedAt)
    #expect(row.lastCopiedAt == originalObservedAt)

    // Canonical Content is untouched by either revision (02 D2); the lineage
    // holds exactly ONE revision — the second — active and carrying its
    // bytes (05 §4).
    let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
    #expect(canonical.representations.map(\.content.bytes) == [Data(originalText.utf8)])
    let lineage = try RevisionStateBlobCodec.decode(row.revisionStateBlob, canonical: canonical)
    #expect(lineage.revisions.count == 1)
    #expect(lineage.activeRevisionID == secondBundle.domain.candidateRevisionID)
    let activeRevision = try #require(lineage.revisions.first)
    #expect(activeRevision.content.representations.map(\.bytes) == [Data(secondRevisedText.utf8)])
    // The §15 durable projection reflects the SECOND revision's Effective
    // Content.
    #expect(row.title == secondRevisedText)
    #expect(row.searchBody == secondRevisedText)

    // WS20: exactly two History Commits happened (insert + the second
    // revision); the stale attempt produced no position (04 §4: no commit,
    // no advance).
    let position = try WSSupport.fetchPosition(verification)
    #expect(position.rawValue == 2)
}
}
