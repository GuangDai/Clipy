/// WS1Composed — Raw capture insert through the composed app stack
/// (docs/06-cross-cutting.md §8 WS1; docs/roadmap/06-clipyapp.md
/// "Acceptance"; docs/roadmap/README.md §3 M3 re-verification): a REAL
/// `PasteboardAdapter.capture` freeze over a private `NSPasteboard` fed to
/// the REAL in-memory `SwiftDataHistory` through the public
/// `ClipboardHistory.perform(.capture(_:))` seam, then read back through the
/// public reads (`browse`, `details`, `pastePayload`) — the composed form of
/// the storage-side WS1 suite, which asserts row/singleton state through an
/// independent `ModelContainer` (that storage-side seam stays there).
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import Testing

struct WS1ComposedCaptureInsertTests {

    /// WS1 (docs/06-cross-cutting.md §8): one frozen pasteboard capture on
    /// an empty store commits once at Change Position 1 with
    /// `.inserted(reference)` at Content Version 1, the observed page
    /// contains the same reference, and the detail/paste reads carry the full
    /// frozen bytes.
    @Test @MainActor
    func adapterCaptureInsertsOneRowVisibleThroughEveryPublicRead() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()

        // A copying application writes plain text; the adapter freezes it
        // (docs/03a-instruction-set.md §4) with a fixed observation time.
        let text = "clipy composed insert probe"
        let observedAt = Date(timeIntervalSinceReferenceDate: 700_200_000)
        let pasteboard = ComposedSupport.makePasteboard()
        ComposedSupport.setPasteboardContents(text, on: pasteboard)
        let adapter = PasteboardAdapter(pasteboard: pasteboard)

        let capture = try #require(
            adapter.capture(observedAt: observedAt),
            "WS1: a non-empty pasteboard yields a capture"
        )
        // The freeze is uninterpreted raw bytes — no concealment, no hint.
        #expect(capture.isConcealed == false)
        #expect(capture.origin.lineageHint == nil)
        #expect(capture.representations.count == 1)
        #expect(
            capture.representations.first?.typeIdentifier
                == ComposedSupport.plainTextTypeIdentifier
        )
        #expect(capture.representations.first?.bytes == Data(text.utf8))

        // perform through the public action seam (docs/03a-instruction-set.md §5).
        let receipt = try await history.perform(.capture(capture))
        let commit = try #require(
            ComposedSupport.commit(of: receipt, "WS1"),
            "WS1: the capture is a History Commit"
        )
        #expect(
            commit.position.rawValue == 1,
            "WS1: first commit moves the position 0 → 1"
        )
        let reference = try #require(
            ComposedSupport.insertedReference(from: receipt, "WS1")
        )
        #expect(
            reference.contentVersion.rawValue == 1,
            "WS1: the inserted reference names the initial Content Version"
        )

        // WS1 observed-page clause: the first page contains the reference
        // (id + contentVersion), with no notification waiting.
        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(page.position.rawValue >= 1)
        #expect(
            page.rows.contains {
                $0.item.id == reference.id
                    && $0.item.contentVersion == reference.contentVersion
            },
            "WS1: the observed page contains the inserted reference"
        )
        #expect(page.rows.count == 1, "WS1: exactly one row")

        // Detail read (docs/03b-instruction-set.md §9): occurrence 1,
        // unpinned, Canonical == Effective == the frozen bytes.
        let details = try await history.details(for: reference.id)
        #expect(details.item == reference)
        #expect(details.occurrence.count == 1)
        #expect(details.pinnedPosition == nil)
        #expect(details.canonical.map(\.typeIdentifier).count == 1)
        #expect(
            details.canonical.first?.bytes == Data(text.utf8),
            "WS1: full Canonical bytes survive the composed round trip"
        )
        #expect(details.effective == details.canonical)

        // Paste read (01 §5.6 input): current Effective Content plus a
        // lineage hint equal to the item — the payload `AppComposition.paste`
        // writes (docs/03b-instruction-set.md §9).
        let payload = try await history.pastePayload(for: reference.id)
        #expect(payload.item == reference)
        #expect(payload.lineageHint == reference.id)
        #expect(payload.representations.map(\.bytes) == [Data(text.utf8)])
    }
}
