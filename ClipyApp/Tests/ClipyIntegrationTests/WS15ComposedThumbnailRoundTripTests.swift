/// WS15Composed — Thumbnail round trip where fixtures allow
/// (docs/06-cross-cutting.md §8 WS15; docs/04-coherence.md §9;
/// docs/03b-instruction-set.md §9): capture a REAL PNG (a minimal valid
/// 1×1 image) through the composed stack, fetch its encoded thumbnail
/// through the public `ClipboardHistory.thumbnail`, decode it through the
/// REAL `ThumbnailStore` (ImageIO on the MainActor), and prove the
/// reference-exact fence: after a revision the OLD reference's pixels are
/// not served under the new one, and a stale-reference request fails typed
/// (`.staleContent`) rather than returning current bytes under the old key.
///
/// The byte-envelope and encode-failure clauses need the storage worker
/// seams and stay in
/// `Tests/HistoryStorageTests/WS15ThumbnailFenceTests.swift`.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import PresentationUI
import Testing

struct WS15ComposedThumbnailRoundTripTests {

    /// Standard minimal 1×1 transparent PNG (the same published fixture
    /// vector the storage-side WS15 suite uses).
    private static let png1x1Base64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    private static func png1x1() -> Data {
        Data(base64Encoded: png1x1Base64)!
    }

    /// WS15 (docs/06-cross-cutting.md §8): the composed round trip — a
    /// `public.png` capture frozen from a private pasteboard, its
    /// thumbnail fetched through the public seam, the encoded PNG decoded
    /// by the real `ThumbnailStore` on the MainActor, and the fence: after
    /// a byte-changing revision the store's OLD key never serves the NEW
    /// pixels and the stale direct request fails `.staleContent`.
    @Test @MainActor
    func pngThumbnailRoundTripsAndTheRevisionFenceHolds() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()

        // Freeze a real PNG through the adapter.
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        pasteboard.setData(Self.png1x1(), forType: NSPasteboard.PasteboardType("public.png"))
        let adapter = PasteboardAdapter(pasteboard: pasteboard)
        let capture = try #require(
            adapter.capture(observedAt: Date(timeIntervalSinceReferenceDate: 700_202_100)),
            "WS15: the PNG freeze yields a capture"
        )
        #expect(
            capture.representations.first?.typeIdentifier == "public.png",
            "WS15: the PNG representation survives the freeze"
        )

        let insertReceipt = try await history.perform(.capture(capture))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS15 arrange")
        )

        // The UTI heuristic gates the panel's prefetch (04 §9); a PNG row
        // is thumbnailable by the frozen v1 set.
        #expect(
            ThumbnailStore.likelyThumbnailable(["public.png"]),
            "WS15: the heuristic admits the PNG row"
        )
        #expect(
            !ThumbnailStore.likelyThumbnailable(["public.utf8-plain-text"]),
            "WS15: the heuristic gates text rows out"
        )

        // The public seam returns ENCODED PNG bytes tagged with the exact
        // requesting reference (03b §9).
        let payload = try await history.thumbnail(
            for: inserted,
            pixels: PixelSize(width: 72, height: 72)
        )
        let encoded = try #require(payload, "WS15: a PNG item has a thumbnail")
        #expect(encoded.item == inserted)
        #expect(encoded.format == .png)
        #expect(encoded.pixels == PixelSize(width: 72, height: 72))
        #expect(
            encoded.encodedBytes.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]),
            "WS15: the payload is a PNG file"
        )

        // The REAL ThumbnailStore decodes it and caches under the exact
        // reference; a pure read without prefetch returns nil first
        // (04 §9: `image(for:)` never fetches).
        let store = ThumbnailStore(history: history)
        #expect(store.image(for: inserted) == nil)
        store.prefetch(inserted)
        let decoded = await ComposedSupport.waitFor {
            store.image(for: inserted) != nil
        }
        #expect(decoded, "WS15: the store decoded and cached the PNG")
        #expect(store.image(for: inserted)?.width == 1)
        #expect(store.image(for: inserted)?.height == 1)

        // Revise the item with byte-different image content: a second
        // minimal PNG (1×1 white). The fence: the OLD cached entry stays
        // under the OLD key, never serving the new pixels; the NEW
        // reference is not yet cached (no stale pixels under the new key).
        let whiteBase64 =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
        let pngWhite = try #require(Data(base64Encoded: whiteBase64))
        #expect(pngWhite != Self.png1x1())
        let reviseReceipt = try await history.perform(.revise(
            RevisionRequest(
                itemID: inserted.id,
                expected: inserted.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(
                        typeIdentifier: "public.png",
                        action: .replace(bytes: pngWhite)
                    ),
                ]))
            )
        ))
        let revised = try #require(
            ComposedSupport.revisedReference(from: reviseReceipt, "WS15 revise")
        )
        #expect(revised.contentVersion != inserted.contentVersion)

        // The old entry remains (reference-exact cache), and the new
        // reference starts uncached — prefetch then lands the NEW pixels.
        #expect(
            store.image(for: inserted) != nil,
            "WS15 (04 §9): the old key keeps its own pixels"
        )
        #expect(
            store.image(for: revised) == nil,
            "WS15 (04 §9): a revised reference never inherits stale pixels"
        )
        store.prefetch(revised)
        let newDecoded = await ComposedSupport.waitFor {
            store.image(for: revised) != nil
        }
        #expect(newDecoded, "WS15: the revised reference fetched its own pixels")
        #expect(store.image(for: inserted) != nil)

        // A stale direct request fails typed rather than returning current
        // bytes under the old key (03b §11 item 7; 04 §9).
        do {
            _ = try await history.thumbnail(
                for: inserted,
                pixels: PixelSize(width: 72, height: 72)
            )
            Issue.record("WS15: expected .staleContent for the stale reference")
        } catch let failure as HistoryFailure {
            guard case let .staleContent(expected, current) = failure else {
                Issue.record("WS15: expected .staleContent, got \(failure)")
                return
            }
            #expect(expected == inserted.contentVersion)
            #expect(current == revised.contentVersion)
        }

        // Text-only items have nothing thumbnailable: `nil`, negative-cached
        // by the store so the row's fallback icon stops re-asking (04 §9).
        let textReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws15 composed text item",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_202_150),
                source: "com.example.ws15composed"
            )
        ))
        let textItem = try #require(
            ComposedSupport.insertedReference(from: textReceipt, "WS15 text arrange")
        )
        let textPayload = try await history.thumbnail(
            for: textItem,
            pixels: PixelSize(width: 72, height: 72)
        )
        #expect(
            textPayload == nil,
            "WS15: a text-only item has no thumbnailable content (03b §9)"
        )
        // The store's negative-cached miss is internal state with no public
        // observer beyond `image(for:) == nil`; the public seam (nil payload)
        // is what the composed panel relies on.
    }
}
