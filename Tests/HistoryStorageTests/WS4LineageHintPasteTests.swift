/// WS4 — Lineage hint for revised Effective Content
/// (docs/06-cross-cutting.md §8 WS4), driven through the public
/// `SwiftDataHistory` facade. After a revision produces a version-2 Effective
/// Content that is a strict subset of Canonical Content, the paste payload's
/// `lineageHint` plus exact Effective-Content byte-set-equality must coalesce a
/// re-capture into the SAME item — preserving Canonical Content and Content
/// Version (docs/02-domain.md §9.3 lane 1) — while a byte-mismatched hint
/// never coalesces (equality, not containment; lane 1 anti-spoofing).
///
/// Unlike WS1/WS3/WS5/WS6 which close step-5/6 commit-side clauses, WS4's
/// core assertion is the PASTE PAYLOAD READ (`pastePayload(for:)`) — a step-7
/// (reads + observation) gate (docs/roadmap/README.md §3). Nothing is deferred:
/// every read path exercised here is implemented at HEAD.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS4LineageHintPasteTests {

/// A `.replace` draft that substitutes new plain-text bytes and HIDES the html
/// type — one decision per Canonical type (docs/03a-instruction-set.md §5),
/// producing a version-2 Effective Content that is plain-only with the new
/// bytes while Canonical Content still carries both representations
/// (docs/02-domain.md §2.6: revision never changes Canonical Content).
private static func replacePlainHideHtmlRequest(
    itemID: HistoryItemID,
    expected: ContentVersion,
    newPlainBytes: Data
) -> RevisionRequest {
    RevisionRequest(
        itemID: itemID,
        expected: expected,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: "public.html",
                action: .hide
            ),
            RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: newPlainBytes)
            ),
        ]))
    )
}

/// Builds a raw capture whose representations are exactly the given set,
/// carrying the given lineage hint and observation (docs/02-domain.md §9.3
/// lane 1: the hint is an observation, not authenticated provenance).
private static func capture(
    representations: [HistoryRepresentation],
    observedAt: Date,
    source: String?,
    lineageHint: HistoryItemID
) -> ClipboardCapture {
    ClipboardCapture(
        representations: representations.map {
            CapturedRepresentation(typeIdentifier: $0.typeIdentifier, bytes: $0.bytes)
        },
        origin: CopyOriginObservation(
            sourceApplication: source,
            lineageHint: lineageHint
        ),
        observedAt: observedAt
    )
}

/// WS4 (docs/06-cross-cutting.md §8): "Revise an item, export its paste
/// payload, and capture that payload with its hint. Exact Effective Content
/// equality must coalesce into the hinted item while preserving Canonical
/// Content and Content Version." This test closes the full scenario:
/// (1) capture a two-representation item, (2) revise it to plain-only with new
/// bytes, (3) read the paste payload, (4) re-capture the payload with its hint
/// and prove lineage-lane coalescing.
@Test func revisedPayloadRecapturedWithLineageHintCoalescesIntoHintedItemPreservingCanonicalAndVersion() async throws {
    let storeURL = WSSupport.tempStoreURL("ws4-lineage-hint-paste")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // ── (1) Capture a two-representation item: plain text + html ──
    let text = "ws4 canonical body"
    let html = "<p>ws4 canonical body</p>"
    let captureObservedAt = Date(timeIntervalSinceReferenceDate: 700_040_000)
    let captureSource = "com.example.ws4.capture"

    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            text,
            observedAt: captureObservedAt,
            source: captureSource,
            extra: [(typeIdentifier: "public.html", bytes: [UInt8](html.utf8))]
        )
    ))
    guard case let .committed(captureCommit) = captureReceipt,
          case let .inserted(inserted) = captureCommit.outcome
    else {
        Issue.record("WS4 (1): expected .committed(.inserted), got \(captureReceipt)")
        return
    }
    // WS4: first commit moves the singleton 0 → 1.
    #expect(
        captureCommit.position.rawValue == 1,
        "WS4 (§8): first capture advances Change Position to 1"
    )
    let itemID = inserted.id
    let version1 = inserted.contentVersion
    #expect(
        version1.rawValue == 1,
        "WS4 (§8): initial Content Version is 1"
    )

    // ── (2) Revise: replace plain-text bytes and HIDE the html type ──
    // One decision per Canonical type (docs/03a-instruction-set.md §5). The
    // proposed Effective Content is plain-ONLY with the NEW bytes; the html
    // Canonical representation is retained for lineage (docs/02-domain.md
    // §2.6; RevisionDecisionAction.hide doc).
    let revisedText = "ws4 revised effective"
    let reviseReceipt = try await history.perform(.revise(
        Self.replacePlainHideHtmlRequest(
            itemID: itemID,
            expected: version1,
            newPlainBytes: Data(revisedText.utf8)
        )
    ))
    guard case let .committed(reviseCommit) = reviseReceipt,
          case let .revised(revised) = reviseCommit.outcome
    else {
        Issue.record("WS4 (2): expected .committed(.revised), got \(reviseReceipt)")
        return
    }
    // WS4: the revision is one History Commit — Change Position advances 1 → 2.
    #expect(
        reviseCommit.position.rawValue == 2,
        "WS4 (§8): revision advances Change Position to 2"
    )
    #expect(
        revised.id == itemID,
        "WS4 (§8): revision keeps the same item id"
    )
    let version2 = revised.contentVersion
    #expect(
        version2.rawValue == 2,
        "WS4 (§8): revision produces Content Version 2"
    )

    // ── (3) Read the paste payload ──
    // WS4: "export its paste payload" — the payload carries current Effective
    // Content only, plus a lineage hint pointing at the item
    // (docs/03b-instruction-set.md §9).
    let payload = try await history.pastePayload(for: itemID)
    // WS4: the payload reference names the current (version-2) Content Version.
    #expect(
        payload.item.contentVersion == version2,
        "WS4 (§8): paste payload item carries Content Version 2"
    )
    #expect(
        payload.item.id == itemID,
        "WS4 (§8): paste payload item id matches the revised item"
    )
    // WS4: payload representations == the revised Effective set — plain-only
    // with the NEW bytes (html was hidden by the revision).
    #expect(
        payload.representations.count == 1,
        "WS4 (§8): paste payload has exactly one representation (html hidden)"
    )
    let payloadRep = try #require(payload.representations.first)
    #expect(
        payloadRep.typeIdentifier == "public.utf8-plain-text",
        "WS4 (§8): paste payload representation is plain text"
    )
    #expect(
        payloadRep.bytes == Data(revisedText.utf8),
        "WS4 (§8): paste payload carries the revised Effective bytes"
    )
    // WS4: the lineage hint points at the item itself.
    #expect(
        payload.lineageHint == itemID,
        "WS4 (§8): paste payload lineage hint is the item id"
    )

    // ── (4) Re-capture the payload with its hint ──
    // WS4: "capture that payload with its hint" — a raw capture whose
    // representations are EXACTLY payload.representations and whose origin
    // carries lineageHint: payload.lineageHint. The lineage lane
    // (docs/02-domain.md §9.3 lane 1) confirms byte-set-equality to the hinted
    // item's current Effective Content → coalesces into the SAME item.
    let recaptureObservedAt = Date(timeIntervalSinceReferenceDate: 700_040_500)
    let recaptureSource = "com.example.ws4.recapture"
    let recaptureReceipt = try await history.perform(.capture(
        Self.capture(
            representations: payload.representations,
            observedAt: recaptureObservedAt,
            source: recaptureSource,
            lineageHint: payload.lineageHint
        )
    ))
    guard case let .committed(recaptureCommit) = recaptureReceipt else {
        Issue.record("WS4 (4): expected a .committed receipt, got \(recaptureReceipt)")
        return
    }
    // WS4: coalescing is a durable mutation — Change Position advances 2 → 3.
    #expect(
        recaptureCommit.position.rawValue == 3,
        "WS4 (§8): lineage-lane coalesce advances Change Position to 3"
    )
    guard case let .coalesced(coalescedReference) = recaptureCommit.outcome else {
        Issue.record("WS4 (4): expected .coalesced(reference), got \(recaptureCommit.outcome)")
        return
    }
    // WS4 (§9.3 lane 1): "coalesce into the hinted item" — same item id.
    #expect(
        coalescedReference.id == itemID,
        "WS4 (§9.3 lane 1): lineage-lane coalesce targets the hinted item"
    )
    // WS4: "preserving … Content Version" — the lineage lane coalesces a copy
    // record, never a revision; Content Version stays at 2
    // (docs/02-domain.md §9.5: coalescing result).
    #expect(
        coalescedReference.contentVersion.rawValue == 2,
        "WS4 (§9.3 lane 1): lineage-lane coalesce preserves Content Version 2"
    )

    // Storage side, through the INDEPENDENT container (no production test
    // seam): no new row, copyCount 2, Content Version still 2, and Canonical
    // Content unchanged (both representations retained, docs/02-domain.md D2).
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    // WS4: "no new row" — the re-capture was absorbed.
    #expect(
        rows.count == 1,
        "WS4 (§8): lineage-lane coalesce persists no second row"
    )
    let row = try #require(rows.first)
    #expect(row.id == itemID.rawValue)
    #expect(
        row.contentVersionRaw == 2,
        "WS4 (§9.3 lane 1): durable Content Version is still 2"
    )
    // WS4: copyCount 2 — the occurrence folded (original capture + re-capture).
    #expect(
        row.copyCount == 2,
        "WS4 (§8): lineage-lane coalesce folds the occurrence to copyCount 2"
    )
    #expect(row.firstCopiedAt == captureObservedAt)
    #expect(row.lastCopiedAt == recaptureObservedAt)
    #expect(row.firstSource == captureSource)
    #expect(row.lastSource == recaptureSource)
    // WS4: "preserving Canonical Content" — both Canonical representations are
    // intact, byte-exact, in normalized order ("public.html" before
    // "public.utf8-plain-text", docs/02-domain.md §2.1). Coalescing never
    // rewrites Canonical Content (D2).
    let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
    #expect(
        canonical.representations.map(\.content.typeIdentifier)
            == ["public.html", "public.utf8-plain-text"],
        "WS4 (§9.3 lane 1): Canonical Content retains both representations"
    )
    #expect(
        canonical.representations.map(\.content.bytes)
            == [Data(html.utf8), Data(text.utf8)],
        "WS4 (§9.3 lane 1): Canonical bytes are byte-exact and unchanged"
    )
    // WS4: the durable singleton matches the receipt's position.
    let position = try WSSupport.fetchPosition(container)
    #expect(
        position.rawValue == 3,
        "WS4 (§7.1): durable singleton matches the coalesce receipt's position"
    )
}

/// WS4 counter-case (docs/02-domain.md §9.3 lane 1): "Containment is
/// insufficient in this lane; equality prevents a spoofed hint from discarding
/// representations." A re-capture carrying the same lineage hint but whose
/// plain-text bytes differ by ONE byte from the payload's Effective Content
/// must NOT coalesce via the lineage lane — and since the mismatched bytes
/// also fail Canonical containment, the result is `.inserted`: a brand-new
/// item. A spoofed/mismatched hint never discards representations.
@Test func lineageLaneEqualityRejectsMismatchedHintAndInsertsNewItem() async throws {
    let storeURL = WSSupport.tempStoreURL("ws4-lineage-hint-mismatch")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Arrange: same two-step setup as the positive case — capture a rich item,
    // revise to plain-only, export the payload.
    let text = "ws4 mismatch canonical"
    let html = "<p>ws4 mismatch canonical</p>"
    let captureObservedAt = Date(timeIntervalSinceReferenceDate: 700_041_000)
    let captureSource = "com.example.ws4.mismatch.capture"

    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            text,
            observedAt: captureObservedAt,
            source: captureSource,
            extra: [(typeIdentifier: "public.html", bytes: [UInt8](html.utf8))]
        )
    ))
    guard case let .committed(captureCommit) = captureReceipt,
          case let .inserted(inserted) = captureCommit.outcome
    else {
        Issue.record("WS4 counter arrange: expected .committed(.inserted), got \(captureReceipt)")
        return
    }
    let itemID = inserted.id
    let version1 = inserted.contentVersion

    let revisedText = "ws4 mismatch revised"
    let reviseReceipt = try await history.perform(.revise(
        Self.replacePlainHideHtmlRequest(
            itemID: itemID,
            expected: version1,
            newPlainBytes: Data(revisedText.utf8)
        )
    ))
    guard case let .committed(reviseCommit) = reviseReceipt,
          case let .revised(revised) = reviseCommit.outcome
    else {
        Issue.record("WS4 counter arrange: expected .committed(.revised), got \(reviseReceipt)")
        return
    }
    #expect(revised.contentVersion.rawValue == 2)

    let payload = try await history.pastePayload(for: itemID)

    // Act: re-capture carrying the SAME lineage hint but with plain-text bytes
    // that differ by ONE byte from the payload's Effective Content. The lineage
    // lane requires byte-set-EQUALITY, not containment (docs/02-domain.md §9.3
    // lane 1), so the mismatched hint cannot coalesce. The Canonical lane
    // (§9.3 lane 2) also fails: the mismatched bytes do not appear in the
    // retained Canonical set. Result: a new item is inserted.
    // Mismatched text: same type identifier as the payload (plain text), but
    // ONE byte different from the revised Effective text. It also differs from
    // the original Canonical text, so neither lane can confirm.
    let mismatchedText = "ws4 mismatch revisee"
    #expect(Data(mismatchedText.utf8) != Data(revisedText.utf8))
    #expect(Data(mismatchedText.utf8) != Data(text.utf8))
    let mismatchObservedAt = Date(timeIntervalSinceReferenceDate: 700_041_500)
    let mismatchSource = "com.example.ws4.mismatch.spoof"
    // The capture carries the SAME lineage hint but different bytes. The plain
    // text type matches the payload; only the bytes differ.
    let mismatchReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            mismatchedText,
            observedAt: mismatchObservedAt,
            source: mismatchSource,
            lineageHint: payload.lineageHint
        )
    ))
    guard case let .committed(mismatchCommit) = mismatchReceipt else {
        Issue.record("WS4 counter: expected a .committed receipt, got \(mismatchReceipt)")
        return
    }
    #expect(
        mismatchCommit.position.rawValue == 3,
        "WS4 (§9.3 lane 1): mismatched-hint insert advances Change Position to 3"
    )
    guard case let .inserted(mismatchedReference) = mismatchCommit.outcome else {
        Issue.record(
            "WS4 counter: expected .inserted(reference) — a mismatched hint must not coalesce — got \(mismatchCommit.outcome)"
        )
        return
    }
    // WS4 (§9.3 lane 1): a spoofed/mismatched hint produces a DISTINCT item.
    #expect(
        mismatchedReference.id != itemID,
        "WS4 (§9.3 lane 1): mismatched-hint insert creates a new distinct item id"
    )
    #expect(
        mismatchedReference.contentVersion.rawValue == 1,
        "WS4 (§9.3 lane 1): mismatched-hint insert starts at Content Version 1"
    )

    // Storage side, through the INDEPENDENT container: TWO rows — the original
    // hinted item untouched, plus the new mismatched item.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(
        rows.count == 2,
        "WS4 (§9.3 lane 1): mismatched-hint insert persists a second row"
    )
    #expect(
        Set(rows.map(\.id)) == Set([itemID.rawValue, mismatchedReference.id.rawValue]),
        "WS4 (§9.3 lane 1): two distinct rows — original hinted item and new mismatched item"
    )
    // WS4: the original item's Content Version and Canonical Content are
    // untouched by the failed lineage-lane probe.
    let originalRow = try #require(rows.first(where: { $0.id == itemID.rawValue }))
    #expect(
        originalRow.contentVersionRaw == 2,
        "WS4 (§9.3 lane 1): original hinted item retains Content Version 2"
    )
    let originalCanonical = try CanonicalBlobCodec.decode(originalRow.canonicalBlob)
    #expect(
        originalCanonical.representations.map(\.content.typeIdentifier)
            == ["public.html", "public.utf8-plain-text"],
        "WS4 (§9.3 lane 1): original item Canonical Content is untouched"
    )
    // WS4: the durable singleton matches the receipt's position.
    let position = try WSSupport.fetchPosition(container)
    #expect(
        position.rawValue == 3,
        "WS4 (§7.1): durable singleton matches the insert receipt's position"
    )
}
}
