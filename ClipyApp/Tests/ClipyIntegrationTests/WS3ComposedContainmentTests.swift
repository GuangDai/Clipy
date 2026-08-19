/// WS3Composed — Rich-to-plain containment through the composed app stack
/// (docs/06-cross-cutting.md §8 WS3; docs/roadmap/06-clipyapp.md
/// "Acceptance"): copying rich content (plain + html) and later copying the
/// same text as PLAIN-ONLY coalesces into the richer Canonical item via the
/// containment lane (docs/02-domain.md §9.3 lane 2) — the composed form of
/// the everyday "copied from a rich app, re-copied from a plain one" path.
///
/// The gate's forced-fingerprint collision clause (equal xxh3 fingerprints,
/// different bytes ⇒ new item) needs the package-only
/// `ForcedCollisionFingerprint` double and stays in the storage-side WS3
/// suite (`Tests/HistoryStorageTests/WS3ContainmentCollisionTests.swift`);
/// the composed stack can only produce honest fingerprints.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import Testing

struct WS3ComposedContainmentTests {

    /// WS3 (docs/06-cross-cutting.md §8): insert rich+plain content, then
    /// submit matching plain-only content through a real adapter freeze.
    /// The plain-only copy coalesces into the richer Canonical item — same
    /// ID, Content Version preserved, Canonical Content still two
    /// representations (D2: coalescing never rewrites Canonical).
    @Test @MainActor
    func plainOnlyCopyOfRichItemCoalescesIntoRicherCanonicalItem() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()

        let text = "clipy composed rich body"
        let html = "<p>clipy composed rich body</p>"
        let richObservedAt = Date(timeIntervalSinceReferenceDate: 700_200_300)
        let plainObservedAt = Date(timeIntervalSinceReferenceDate: 700_200_400)
        let pasteboard = ComposedSupport.makePasteboard()
        let adapter = PasteboardAdapter(pasteboard: pasteboard)

        // Rich copy: plain + html siblings (docs/03a-instruction-set.md §4).
        ComposedSupport.setPasteboardContents(text, html: html, on: pasteboard)
        let richCapture = try #require(adapter.capture(observedAt: richObservedAt))
        #expect(richCapture.representations.count == 2)

        let insertReceipt = try await history.perform(.capture(richCapture))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS3 arrange")
        )

        // Plain-only copy of the SAME text — a subset of the rich item's
        // Canonical types with byte-equal plain bytes (containment,
        // docs/02-domain.md §9.3 lane 2).
        ComposedSupport.setPasteboardContents(text, on: pasteboard)
        let plainCapture = try #require(adapter.capture(observedAt: plainObservedAt))
        #expect(plainCapture.representations.count == 1)

        let receipt = try await history.perform(.capture(plainCapture))
        let commit = try #require(
            ComposedSupport.commit(of: receipt, "WS3"),
            "WS3: the contained copy is a History Commit"
        )
        #expect(
            commit.position.rawValue == 2,
            "WS3: containment coalesce advances Change Position once"
        )
        let coalesced = try #require(
            ComposedSupport.coalescedReference(from: receipt, "WS3")
        )
        #expect(
            coalesced.id == inserted.id,
            "WS3: the plain-only copy coalesces into the richer item"
        )
        #expect(
            coalesced.contentVersion.rawValue == 1,
            "WS3: containment coalesce preserves Content Version"
        )

        // One item, Canonical Content unchanged: both representations
        // retained, byte-exact (D2), occurrence folded to 2 (05 §9).
        let details = try await history.details(for: inserted.id)
        #expect(
            Set(details.canonical.map(\.typeIdentifier))
                == Set(["public.html", ComposedSupport.plainTextTypeIdentifier]),
            "WS3: Canonical Content keeps both rich representations"
        )
        #expect(
            details.canonical.contains {
                $0.typeIdentifier == "public.html" && $0.bytes == Data(html.utf8)
            },
            "WS3: the html Canonical bytes are unchanged"
        )
        #expect(details.occurrence.count == 2)

        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(
            page.rows.count == 1,
            "WS3: no second row — the plain copy was absorbed"
        )
    }
}
