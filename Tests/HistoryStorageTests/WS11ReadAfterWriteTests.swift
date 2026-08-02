/// WS11 — Receipt read-after-write (docs/06-cross-cutting.md §8 WS11;
/// docs/04-coherence.md §3): after every committed outcome family, the
/// relevant public read — browse, details, pastePayload — observes that
/// commit's position/reference/state immediately, with no notification
/// waiting or manual refresh.
///
/// This file is ALSO the public-side §7.2 fresh-context-visibility evidence
/// (docs/06-cross-cutting.md §7.2; docs/roadmap/03-historystorage.md §7.2):
/// a read that begins after a `.committed` receipt, through a fresh
/// `ModelContext` over the same store, sees the committed transaction
/// immediately — the BLOCKER proof WS11 rests on. It is the public-facade
/// companion to `FreshContextVisibilityProofTests` (storage-side).
///
/// One store; one sequential scenario that runs every committed outcome
/// family — insert, coalesce, placePinned, revise, remove, clear, and
/// setRetentionPolicy — each immediately followed by the relevant public
/// read(s). 04 §3: "any browse, details, pastePayload … that begins
/// afterward must observe durable position >= commit.position."
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS11ReadAfterWriteTests {

/// A `.replace` revision request (docs/03a-instruction-set.md §5) for the
/// single `public.utf8-plain-text` representation, OCC-tokened at `expected`.
private static func replaceTextRequest(
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

/// WS11 (docs/06-cross-cutting.md §8; docs/04-coherence.md §3): every
/// committed outcome family — insert, coalesce, placePinned, revise, remove,
/// clear, and setRetentionPolicy — is observable through the relevant public
/// read immediately after the `.committed` receipt, with no notification
/// waiting or manual refresh. Each browse page's position is >= the commit's
/// position (04 §3: a read begun after the receipt observes at least its
/// position).
@Test func readAfterEveryCommittedOutcomeFamilyObservesTheCommitWithoutRefresh() async throws {
    let storeURL = WSSupport.tempStoreURL("ws11-read-after-write")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let limit = 50

    // ── (a) capture → browse + details ───────────────────────────────

    let textA = "ws11 read-after-write alpha"
    let t1 = Date(timeIntervalSinceReferenceDate: 700_040_000)
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(textA, observedAt: t1, source: "com.example.ws11.alpha")
    ))
    guard case let .committed(captureCommit) = captureReceipt,
          case let .inserted(alphaRef) = captureCommit.outcome
    else {
        Issue.record("WS11 (a): expected .committed(.inserted), got \(captureReceipt)")
        return
    }

    // WS11 (a): browse(.recent) first page contains the reference (id +
    // contentVersion), and its position is >= the commit's (04 §3).
    let browseAfterCapture = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: limit)
    )
    #expect(
        browseAfterCapture.position >= captureCommit.position,
        "WS11 (a) (04 §3): browse position \(browseAfterCapture.position.rawValue) >= commit \(captureCommit.position.rawValue)"
    )
    #expect(
        browseAfterCapture.rows.contains {
            $0.item.id == alphaRef.id && $0.item.contentVersion == alphaRef.contentVersion
        },
        "WS11 (a): browse first page contains the inserted reference (id + contentVersion)"
    )

    // WS11 (a): details(for:) returns Content Version 1.
    let detailsAfterCapture = try await history.details(for: alphaRef.id)
    #expect(
        detailsAfterCapture.item.contentVersion.rawValue == 1,
        "WS11 (a): details reports Content Version 1 for the initial capture"
    )

    // ── (b) coalesce (same capture again) → details + browse ─────────

    let t2 = Date(timeIntervalSinceReferenceDate: 700_040_100)
    let coalesceReceipt = try await history.perform(.capture(
        WSSupport.textCapture(textA, observedAt: t2, source: "com.example.ws11.coalesce")
    ))
    guard case let .committed(coalesceCommit) = coalesceReceipt,
          case let .coalesced(coalescedRef) = coalesceCommit.outcome
    else {
        Issue.record("WS11 (b): expected .committed(.coalesced), got \(coalesceReceipt)")
        return
    }
    #expect(coalescedRef.id == alphaRef.id)

    // WS11 (b): details shows copyCount 2 at the SAME Content Version.
    let detailsAfterCoalesce = try await history.details(for: alphaRef.id)
    #expect(
        detailsAfterCoalesce.occurrence.count == 2,
        "WS11 (b): details reports copyCount 2 after the coalescing capture"
    )
    #expect(
        detailsAfterCoalesce.item.contentVersion.rawValue == 1,
        "WS11 (b): details reports the SAME Content Version — coalescing mints no version"
    )

    // WS11 (b): browse still one row, position >= the coalesce commit.
    let browseAfterCoalesce = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: limit)
    )
    #expect(
        browseAfterCoalesce.position >= coalesceCommit.position,
        "WS11 (b) (04 §3): browse position >= coalesce commit"
    )
    #expect(
        browseAfterCoalesce.rows.count == 1,
        "WS11 (b): browse still one row — coalescing adds no second item"
    )

    // ── (c) placePinned → browse ─────────────────────────────────────

    let pinReceipt = try await history.perform(.placePinned(alphaRef.id, at: .last))
    guard case let .committed(pinCommit) = pinReceipt,
          case let .placedPinned(pinnedID) = pinCommit.outcome,
          pinnedID == alphaRef.id
    else {
        Issue.record("WS11 (c): expected .committed(.placedPinned), got \(pinReceipt)")
        return
    }

    // WS11 (c): browse first row is alpha at pinnedPosition 0.
    let browseAfterPin = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: limit)
    )
    #expect(
        browseAfterPin.position >= pinCommit.position,
        "WS11 (c) (04 §3): browse position >= pin commit"
    )
    let pinnedRow = try #require(browseAfterPin.rows.first)
    #expect(
        pinnedRow.item.id == alphaRef.id,
        "WS11 (c): browse first row is the pinned item"
    )
    #expect(
        pinnedRow.pinnedPosition == 0,
        "WS11 (c): browse first row pinnedPosition == 0"
    )

    // ── (d) revise (byte-changing replace) → details + pastePayload ──

    let revisedTextA = "ws11 revised effective alpha"
    let reviseReceipt = try await history.perform(.revise(
        Self.replaceTextRequest(
            itemID: alphaRef.id,
            expected: alphaRef.contentVersion,
            text: revisedTextA
        )
    ))
    guard case let .committed(reviseCommit) = reviseReceipt,
          case let .revised(revisedRef) = reviseCommit.outcome
    else {
        Issue.record("WS11 (d): expected .committed(.revised), got \(reviseReceipt)")
        return
    }
    #expect(revisedRef.id == alphaRef.id)
    #expect(revisedRef.contentVersion.rawValue == 2)

    // WS11 (d): details shows the new version + revision list.
    let detailsAfterRevise = try await history.details(for: alphaRef.id)
    #expect(
        detailsAfterRevise.item.contentVersion.rawValue == 2,
        "WS11 (d): details reports Content Version 2 after the revision"
    )
    #expect(
        detailsAfterRevise.revisions.count == 1,
        "WS11 (d): details reports one revision in the lineage"
    )
    let activeRevision = try #require(detailsAfterRevise.revisions.first)
    #expect(
        activeRevision.isActive,
        "WS11 (d): the single revision is the active one"
    )
    // WS11 (d): effective carries the NEW bytes; canonical keeps the ORIGINAL.
    #expect(
        detailsAfterRevise.effective.contains {
            $0.typeIdentifier == "public.utf8-plain-text"
                && $0.bytes == Data(revisedTextA.utf8)
        },
        "WS11 (d): details effective carries the revised bytes"
    )
    #expect(
        detailsAfterRevise.canonical.contains {
            $0.typeIdentifier == "public.utf8-plain-text"
                && $0.bytes == Data(textA.utf8)
        },
        "WS11 (d): details canonical keeps the original bytes"
    )

    // WS11 (d): pastePayload returns the NEW (revised) bytes.
    let payloadAfterRevise = try await history.pastePayload(for: alphaRef.id)
    #expect(
        payloadAfterRevise.item.contentVersion.rawValue == 2,
        "WS11 (d): pastePayload references Content Version 2"
    )
    #expect(
        payloadAfterRevise.representations.contains {
            $0.typeIdentifier == "public.utf8-plain-text"
                && $0.bytes == Data(revisedTextA.utf8)
        },
        "WS11 (d): pastePayload returns the revised Effective Content bytes"
    )

    // WS11 (d): browse position >= the revise commit.
    let browseAfterRevise = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: limit)
    )
    #expect(
        browseAfterRevise.position >= reviseCommit.position,
        "WS11 (d) (04 §3): browse position >= revise commit"
    )

    // ── (e) capture 2 more, remove one → browse + details(.notFound) ──

    let t5 = Date(timeIntervalSinceReferenceDate: 700_041_000)
    let bravoReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws11 read-after-write bravo",
            observedAt: t5,
            source: "com.example.ws11.bravo"
        )
    ))
    guard case let .committed(bravoCommit) = bravoReceipt,
          case let .inserted(bravoRef) = bravoCommit.outcome
    else {
        Issue.record("WS11 (e): expected .committed(.inserted) for bravo, got \(bravoReceipt)")
        return
    }

    let t6 = Date(timeIntervalSinceReferenceDate: 700_041_100)
    let charlieReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws11 read-after-write charlie",
            observedAt: t6,
            source: "com.example.ws11.charlie"
        )
    ))
    guard case let .committed(charlieCommit) = charlieReceipt,
          case .inserted = charlieCommit.outcome
    else {
        Issue.record("WS11 (e): expected .committed(.inserted) for charlie, got \(charlieReceipt)")
        return
    }

    let removeReceipt = try await history.perform(.remove(bravoRef.id))
    guard case let .committed(removeCommit) = removeReceipt,
          case .removed(count: 1) = removeCommit.outcome
    else {
        Issue.record("WS11 (e): expected .committed(.removed(count: 1)), got \(removeReceipt)")
        return
    }

    // WS11 (e): browse no longer contains bravo.
    let browseAfterRemove = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: limit)
    )
    #expect(
        browseAfterRemove.position >= removeCommit.position,
        "WS11 (e) (04 §3): browse position >= remove commit"
    )
    #expect(
        !browseAfterRemove.rows.contains { $0.item.id == bravoRef.id },
        "WS11 (e): browse no longer contains the removed item"
    )

    // WS11 (e): details(for: bravo) throws .notFound.
    await #expect(throws: HistoryFailure.notFound(bravoRef.id)) {
        try await history.details(for: bravoRef.id)
    }

    // ── (f) clear(.unpinned) → browse only pinned ────────────────────

    let clearReceipt = try await history.perform(.clear(.unpinned))
    guard case let .committed(clearCommit) = clearReceipt,
          case let .cleared(clearedCount) = clearCommit.outcome
    else {
        Issue.record("WS11 (f): expected .committed(.cleared), got \(clearReceipt)")
        return
    }
    #expect(
        clearedCount == 1,
        "WS11 (f): one unpinned item (charlie) was cleared"
    )

    // WS11 (f): browse contains only pinned rows.
    let browseAfterClear = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: limit)
    )
    #expect(
        browseAfterClear.position >= clearCommit.position,
        "WS11 (f) (04 §3): browse position >= clear commit"
    )
    #expect(
        browseAfterClear.rows.allSatisfy { $0.pinnedPosition != nil },
        "WS11 (f): browse contains only pinned rows after .clear(.unpinned)"
    )
    #expect(
        browseAfterClear.rows.contains { $0.item.id == alphaRef.id },
        "WS11 (f): the pinned alpha survives the unpinned clear"
    )

    // ── (g) capture 2 more, setRetentionPolicy(1) → browse ───────────

    let t9 = Date(timeIntervalSinceReferenceDate: 700_042_000)
    let deltaReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws11 read-after-write delta",
            observedAt: t9,
            source: "com.example.ws11.delta"
        )
    ))
    guard case let .committed(deltaCommit) = deltaReceipt,
          case let .inserted(deltaRef) = deltaCommit.outcome
    else {
        Issue.record("WS11 (g): expected .committed(.inserted) for delta, got \(deltaReceipt)")
        return
    }

    let t10 = Date(timeIntervalSinceReferenceDate: 700_042_100)
    let echoReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws11 read-after-write echo",
            observedAt: t10,
            source: "com.example.ws11.echo"
        )
    ))
    guard case let .committed(echoCommit) = echoReceipt,
          case let .inserted(echoRef) = echoCommit.outcome
    else {
        Issue.record("WS11 (g): expected .committed(.inserted) for echo, got \(echoReceipt)")
        return
    }

    let retentionReceipt = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 1))
    guard case let .committed(retentionCommit) = retentionReceipt,
          case let .retentionPolicySet(removedCount) = retentionCommit.outcome
    else {
        Issue.record("WS11 (g): expected .committed(.retentionPolicySet), got \(retentionReceipt)")
        return
    }
    #expect(
        removedCount == 1,
        "WS11 (g): one oldest unpinned item (delta) was retired by the policy"
    )

    // WS11 (g): browse shows only the policy-surviving unpinned row + pinned.
    let browseAfterRetention = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: limit)
    )
    #expect(
        browseAfterRetention.position >= retentionCommit.position,
        "WS11 (g) (04 §3): browse position >= retention commit"
    )
    let retainedIDs = Set(browseAfterRetention.rows.map(\.item.id))
    #expect(
        retainedIDs == Set([alphaRef.id, echoRef.id]),
        "WS11 (g): browse shows only alpha (pinned) and echo (surviving unpinned)"
    )
    #expect(
        !retainedIDs.contains(deltaRef.id),
        "WS11 (g): delta (oldest unpinned) was retired by the retention policy"
    )
}

/// WS11 / §7.2 (docs/06-cross-cutting.md §8 WS11, §7.2; docs/04-coherence.md
/// §3, §5): the first page yielded by `observe` after a `.committed` receipt
/// carries a position >= the commit's, proving fresh-context visibility
/// through the observation path. Observe yields pages forever; the stream is
/// drained for exactly one page and the consuming Task is cancelled (defer).
@Test func observedFirstPageAfterCaptureCarriesCommitPosition() async throws {
    let storeURL = WSSupport.tempStoreURL("ws11-observe")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let observedAt = Date(timeIntervalSinceReferenceDate: 700_050_000)
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "ws11 observe probe",
            observedAt: observedAt,
            source: "com.example.ws11.observe"
        )
    ))
    guard case let .committed(commit) = receipt,
          case let .inserted(reference) = commit.outcome
    else {
        Issue.record("WS11 observe: expected .committed(.inserted), got \(receipt)")
        return
    }

    // §7.2: observe started AFTER the receipt yields a first page whose
    // position >= the commit's (04 §3). Drain exactly one page then cancel.
    let stream = history.observe(HistoryObservationRequest(kind: .recent, limit: 10))
    let consumeTask = Task {
        for try await page in stream {
            return page
        }
        return nil as HistoryPage?
    }
    defer { consumeTask.cancel() }
    let pageValue = try await consumeTask.value
    guard let firstPage = pageValue else {
        Issue.record("WS11 observe: the stream yielded no page")
        return
    }

    // WS11 (04 §3): the observed first page position >= the commit's.
    #expect(
        firstPage.position >= commit.position,
        "WS11 (04 §3): observed first page position \(firstPage.position.rawValue) >= commit \(commit.position.rawValue)"
    )
    // WS11: the page contains the just-captured reference.
    #expect(
        firstPage.rows.contains {
            $0.item.id == reference.id && $0.item.contentVersion == reference.contentVersion
        },
        "WS11: observed first page contains the captured reference (id + contentVersion)"
    )
}
}
