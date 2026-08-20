/// WS4Composed — Lineage hint for revised Effective Content, driven through
/// the app's paste orchestration (docs/06-cross-cutting.md §8 WS4;
/// docs/01-architecture.md §5.6; docs/03b-instruction-set.md §9;
/// docs/04-coherence.md §8): revise an item, export its paste payload,
/// WRITE it to a real (private) pasteboard exactly as `AppComposition.paste`
/// does (`history.pastePayload(for:)` → `adapter.write(payload)` — everything
/// outside any History transaction), then re-capture that pasteboard through
/// the real adapter and prove the lineage round trip coalesces back into the
/// hinted item.
///
/// This is the composed end-to-end form of the app-level paste guarantee
/// (roadmap 06 acceptance): Effective Content + lineage hint on the
/// pasteboard, recognized on the way back in. The `NSApp.hide` side of
/// orchestration is a window effect with no assertable History state and is
/// intentionally not driven here.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import Testing

struct WS4ComposedLineageRoundTripTests {

    /// A `.replace` draft that substitutes new plain-text bytes and HIDES the
    /// html type — one decision per Canonical type (docs/03a-instruction-set.md
    /// §5) — producing plain-only version-2 Effective Content while Canonical
    /// Content keeps both representations (docs/02-domain.md §2.6).
    private static func replacePlainHideHtmlRequest(
        itemID: HistoryItemID,
        expected: ContentVersion,
        newPlainBytes: Data
    ) -> RevisionRequest {
        RevisionRequest(
            itemID: itemID,
            expected: expected,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: "public.html", action: .hide),
                RevisionDecision(
                    typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                    action: .replace(bytes: newPlainBytes)
                ),
            ]))
        )
    }

    /// WS4 (docs/06-cross-cutting.md §8): "Revise an item, export its paste
    /// payload, and capture that payload with its hint. Exact Effective
    /// Content equality must coalesce into the hinted item while preserving
    /// Canonical Content and Content Version." Here the "capture that
    /// payload" step is the REAL adapter reading a REAL pasteboard the app's
    /// own `write(_:)` just populated — the complete paste round trip.
    @Test @MainActor
    func pasteWriteThenRecaptureCoalescesIntoHintedItemPreservingCanonical() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()

        let text = "ws4 composed canonical body"
        let html = "<p>ws4 composed canonical body</p>"
        let captureObservedAt = Date(timeIntervalSinceReferenceDate: 700_200_500)
        let recaptureObservedAt = Date(timeIntervalSinceReferenceDate: 700_200_600)

        // (1) Capture a two-representation item through the adapter.
        let pasteboard = ComposedSupport.makePasteboard()
        let adapter = PasteboardAdapter(pasteboard: pasteboard)
        ComposedSupport.setPasteboardContents(text, html: html, on: pasteboard)
        let capture = try #require(adapter.capture(observedAt: captureObservedAt))
        let insertReceipt = try await history.perform(.capture(capture))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS4 (1)")
        )
        let itemID = inserted.id

        // (2) Revise to plain-only Effective Content with new bytes.
        let revisedText = "ws4 composed revised effective"
        let reviseReceipt = try await history.perform(.revise(
            Self.replacePlainHideHtmlRequest(
                itemID: itemID,
                expected: inserted.contentVersion,
                newPlainBytes: Data(revisedText.utf8)
            )
        ))
        let revised = try #require(
            ComposedSupport.revisedReference(from: reviseReceipt, "WS4 (2)")
        )
        #expect(revised.contentVersion.rawValue == 2)

        // (3) The app's paste orchestration (01 §5.6): resolve the payload,
        // then write it to the pasteboard — Effective Content
        // representations plus the lineage hint (03b §9; 04 §8), no
        // History transaction involved.
        let payload = try await history.pastePayload(for: itemID)
        #expect(payload.item.contentVersion == revised.contentVersion)
        #expect(payload.lineageHint == itemID)
        #expect(payload.representations.count == 1, "html is hidden from Effective")
        #expect(
            payload.representations.first?.bytes == Data(revisedText.utf8)
        )
        try adapter.write(payload)

        // (4) The capture loop's next poll freezes the pasted content: the
        // hint decodes into the origin and is NOT retained as content
        // (docs/03a-instruction-set.md §4; PasteboardLineageHint).
        let recapture = try #require(
            adapter.capture(observedAt: recaptureObservedAt),
            "WS4 (4): the written payload is re-captured"
        )
        #expect(recapture.origin.lineageHint == itemID)
        #expect(recapture.isConcealed == false)
        #expect(
            recapture.representations.map(\.bytes) == payload.representations.map(\.bytes),
            "WS4 (4): the re-captured bytes equal the pasted Effective Content"
        )
        #expect(
            !recapture.representations.contains {
                $0.typeIdentifier == "com.clipy.lineageHint"
            },
            "WS4 (4): the hint type never survives as content"
        )

        // The lineage lane (docs/02-domain.md §9.3 lane 1): byte-set-equal
        // Effective Content coalesces into the hinted item.
        let recaptureReceipt = try await history.perform(.capture(recapture))
        let commit = try #require(
            ComposedSupport.commit(of: recaptureReceipt, "WS4 (4)")
        )
        #expect(
            commit.position.rawValue == 3,
            "WS4: the round-trip coalesce advances Change Position once"
        )
        let coalesced = try #require(
            ComposedSupport.coalescedReference(from: recaptureReceipt, "WS4 (4)")
        )
        #expect(coalesced.id == itemID, "WS4: coalesces into the hinted item")
        #expect(
            coalesced.contentVersion.rawValue == 2,
            "WS4: Content Version preserved — a copy record, never a revision"
        )

        // Canonical Content untouched by both the revision's hide and the
        // coalesce (docs/02-domain.md D2); occurrence folded to 2.
        let details = try await history.details(for: itemID)
        #expect(
            Set(details.canonical.map(\.typeIdentifier))
                == Set(["public.html", ComposedSupport.plainTextTypeIdentifier]),
            "WS4: Canonical Content still carries both representations"
        )
        #expect(details.effective.count == 1)
        #expect(details.effective.first?.bytes == Data(revisedText.utf8))
        #expect(details.occurrence.count == 2)
    }

    /// WS4 counter-case (docs/02-domain.md §9.3 lane 1): the lineage lane
    /// requires byte-set EQUALITY — a capture carrying the payload's hint
    /// but ONE byte of different plain text must not coalesce; neither lane
    /// can confirm, so a new distinct item is inserted. Built as a direct
    /// capture (the adapter can only write hints paired with their own
    /// bytes, which is precisely the anti-spoofing point under test).
    @Test @MainActor
    func mismatchedHintBytesInsertADistinctItemInsteadOfCoalescing() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()

        let text = "ws4 composed mismatch canonical"
        let html = "<p>ws4 composed mismatch canonical</p>"
        let pasteboard = ComposedSupport.makePasteboard()
        let adapter = PasteboardAdapter(pasteboard: pasteboard)
        ComposedSupport.setPasteboardContents(text, html: html, on: pasteboard)
        let capture = try #require(
            adapter.capture(observedAt: Date(timeIntervalSinceReferenceDate: 700_200_700))
        )
        let insertReceipt = try await history.perform(.capture(capture))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS4 counter arrange")
        )

        let revisedText = "ws4 composed mismatch revised"
        let reviseReceipt = try await history.perform(.revise(
            Self.replacePlainHideHtmlRequest(
                itemID: inserted.id,
                expected: inserted.contentVersion,
                newPlainBytes: Data(revisedText.utf8)
            )
        ))
        _ = try #require(
            ComposedSupport.revisedReference(from: reviseReceipt, "WS4 counter arrange")
        )
        let payload = try await history.pastePayload(for: inserted.id)

        // ONE byte different from the payload's Effective Content, same
        // hint: neither lineage equality nor Canonical containment holds.
        let mismatchedText = "ws4 composed mismatch revisee"
        #expect(Data(mismatchedText.utf8) != Data(revisedText.utf8))
        #expect(Data(mismatchedText.utf8) != Data(text.utf8))
        let mismatchReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                mismatchedText,
                observedAt: Date(timeIntervalSinceReferenceDate: 700_200_800),
                source: "com.example.ws4composed.spoof",
                lineageHint: payload.lineageHint
            )
        ))
        let mismatched = try #require(
            ComposedSupport.insertedReference(from: mismatchReceipt, "WS4 counter")
        )
        #expect(
            mismatched.id != inserted.id,
            "WS4 (§9.3 lane 1): a spoofed hint never discards representations"
        )
        #expect(mismatched.contentVersion.rawValue == 1)

        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(
            page.rows.count == 2,
            "WS4 counter: the mismatched copy persists as a second row"
        )
    }
}
