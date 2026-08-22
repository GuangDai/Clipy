/// PasteboardAdapter real-scale stress/smoke slice (fixture suite D):
/// the capture freeze and paste write proven against the real-scale
/// `fixtures-v1` payloads — 4K image bytes, 5 MiB text, a rapid write
/// burst under changeCount polling, and concealed 5 MiB content.
/// Owning spec: docs/03a-instruction-set.md §4 (capture freeze),
/// docs/03b-instruction-set.md §9 (paste write / lineage hint),
/// docs/04-coherence.md §8 (paste coherence),
/// docs/05-authority-kernel.md §6.1 (concealment markers),
/// docs/01-architecture.md §5.1/§5.6; roadmap
/// docs/roadmap/04-pasteboardadapter.md.
///
/// Fixture payloads come from the `clipy-fixtures-v1` release tree (see
/// `FixtureCatalog.swift` in this target). The whole suite is gated with
/// `.enabled(if: FixtureCatalog.available, …)` so a fresh clone's
/// `swift test` stays green without the tree (06 §8 test-independence
/// spirit); CI always fetches the tree via `scripts/fetch_fixtures.sh` and
/// the fetch step fails the job on any download/checksum error, so a
/// silent skip on CI is impossible.
///
/// Like the acceptance suite, every test uses a private
/// `NSPasteboard(name:)` with a unique name, so the suite never reads or
/// mutates the user's clipboard. The adapter never fingerprints or
/// coalesces here — byte equality is proven at the adapter seam only;
/// end-to-end dedup/coalescing stays behind `ClipboardHistory`
/// (01 §3 "Must not own").
import AppKit
import Foundation
import HistoryCore
import Testing
@testable import PasteboardAdapter

@Suite(
    "PasteboardAdapter real-scale stress (fixtures-v1)",
    .enabled(
        if: FixtureCatalog.available,
        "clipy-fixtures-v1 tree absent (CLIPY_FIXTURES_DIR unset)"
    )
)
@MainActor
struct PasteboardAdapterStressTests {
    // MARK: - Suite-local helpers (mirrors of PasteboardAdapterTests'
    // file-private fixtures; SwiftPM test files share nothing)

    /// A fresh, uniquely named private pasteboard per test.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(
            name: NSPasteboard.Name(
                "com.clipy.pasteboardadapterstresstests." + UUID().uuidString
            )
        )
    }

    /// Spins the main run loop in short slices until `condition` holds or
    /// `timeout` elapses, servicing the observer's main-RunLoop `Timer`
    /// (whose block polls synchronously on the main actor) while the
    /// synchronous test body waits. Returns whether the condition was met.
    private func spinMainRunLoop(
        until condition: () -> Bool,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    /// Fabricates a paste payload the way the composition root hands one to
    /// the adapter on paste (03b §9): current Effective Content
    /// representations plus a lineage hint equal to the item ID. ID minting
    /// is package-only; the test target shares the SwiftPM package, so it
    /// mints directly like the acceptance suite does
    /// (`HistoryItemID(rawValue: UUID())`).
    private func makePayload(
        typeIdentifier: String,
        bytes: Data
    ) -> PastePayload {
        let id = HistoryItemID(rawValue: UUID())
        return PastePayload(
            item: HistoryItemReference(id: id, contentVersion: ContentVersion(rawValue: 1)),
            representations: [
                HistoryRepresentation(typeIdentifier: typeIdentifier, bytes: bytes)
            ],
            lineageHint: id
        )
    }

    // MARK: - 4K image round trip (03a §4; 03b §9; 04 §8)

    /// A real 4K PNG (≈848 KiB, `images/photo4k-a.png`) survives the
    /// paste-write → capture-freeze round trip byte-exact, with the frozen
    /// type set exactly `{public.png}` — the lineage-hint marker type is
    /// metadata and must not survive as a retained representation
    /// (03a §4; 03b §9).
    @Test func fourKImageRoundTripsThroughPasteWriteAndCapture() throws {
        let pngBytes = try FixtureCatalog.data("images/photo4k-a.png")
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let adapter = PasteboardAdapter(pasteboard: pasteboard)
        let payload = makePayload(typeIdentifier: "public.png", bytes: pngBytes)

        try adapter.write(payload)

        let capture = adapter.capture()
        #expect(capture != nil)
        #expect(capture?.isConcealed == false)
        #expect(capture?.origin.lineageHint == payload.lineageHint)
        #expect(capture?.representations.count == 1)
        #expect(capture?.representations.first?.typeIdentifier == "public.png")
        #expect(capture?.representations.first?.bytes == pngBytes)
    }

    // MARK: - 5 MiB text round trip with lineage hint (03b §9; 04 §8)

    /// A real 5 MiB text payload (`text/lorem-5mb.txt`) round-trips
    /// byte-exact under `public.utf8-plain-text`, and the lineage hint is
    /// preserved in BOTH directions of the paste flow (03b §9; 04 §8):
    /// the write direction leaves the exact hint wire bytes on the
    /// pasteboard under `com.clipy.lineageHint`, and the capture direction
    /// decodes them back into `CopyOriginObservation.lineageHint` while
    /// excluding the marker type from the frozen representations.
    @Test func fiveMegabyteTextRoundTripsWithLineageHintPreserved() throws {
        let textBytes = Data(try FixtureCatalog.text("text/lorem-5mb.txt").utf8)
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let adapter = PasteboardAdapter(pasteboard: pasteboard)
        let payload = makePayload(
            typeIdentifier: "public.utf8-plain-text",
            bytes: textBytes
        )

        try adapter.write(payload)

        // Write direction: content bytes and hint wire bytes on the board.
        let item = pasteboard.pasteboardItems?.first
        #expect(item?.data(forType: .string) == textBytes)
        #expect(
            item?.data(forType: NSPasteboard.PasteboardType(PasteboardLineageHint.typeIdentifier))
                == PasteboardLineageHint.encode(payload.lineageHint)
        )

        // Capture direction: hint decoded into the origin, marker type
        // excluded from the frozen representations, content byte-exact.
        let capture = adapter.capture()
        #expect(capture != nil)
        #expect(capture?.isConcealed == false)
        #expect(capture?.origin.lineageHint == payload.lineageHint)
        #expect(capture?.representations.count == 1)
        #expect(
            capture?.representations.first?.typeIdentifier
                == NSPasteboard.PasteboardType.string.rawValue
        )
        #expect(capture?.representations.first?.bytes == textBytes)
    }

    // MARK: - Rapid write burst under observation (01 §5.1; roadmap 04
    // deliverable 3)

    /// Thirty writes land in one synchronous burst while the observer polls
    /// at a tightened interval. The observer contract (01 §5.1; roadmap 04
    /// acceptance 4) bounds delivery: at most one capture per distinct
    /// `changeCount`, and at most one initial capture on `start` — so the
    /// delivered count stays within 1…31 no matter how the run loop
    /// interleaves. The LAST delivered capture must freeze the last write,
    /// and after `stop()` a 0.5 s quiet window with a further write
    /// delivers nothing.
    ///
    /// Determinism: the burst body never yields the main thread, so in
    /// practice exactly one poll observes the burst; the bounded assertion
    /// (not an exact count) is what keeps the test honest if AppKit ever
    /// services the timer between writes.
    @Test func rapidWriteBurstDeliversBoundedCapturesWithLastWriteWinning() throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let observer = PasteboardObserver(
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            pollInterval: 0.02
        )

        var received: [ClipboardCapture] = []
        observer.start { outcome in
            guard case let .complete(value) = outcome else {
                Issue.record("stable stress writes must produce complete freezes")
                return
            }
            received.append(value.capture)
        }

        // The burst: 30 distinct writes, no run-loop yields between them.
        let writeCount = 30
        for index in 0..<writeCount {
            pasteboard.clearContents()
            pasteboard.setString("stress-write-\(index)", forType: .string)
        }
        let lastWriteBytes = Data("stress-write-\(writeCount - 1)".utf8)

        // At least one capture must land; give the poll a generous window
        // (≥1 s) before asserting.
        #expect(spinMainRunLoop(until: { received.count >= 1 }, timeout: 2))
        // The initial capture on start found an empty pasteboard (nil, not
        // delivered), and polling delivers at most once per distinct change
        // count: delivered ∈ 1…(1 initial + 30 writes).
        #expect(received.count >= 1)
        #expect(received.count <= writeCount + 1)
        // The last delivered capture froze the LAST write — no stale or
        // intermediate tail.
        #expect(
            received.last?.representations.contains {
                $0.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue
                    && $0.bytes == lastWriteBytes
            } == true
        )

        observer.stop()
        let deliveredAtStop = received.count

        // A post-stop write bumps the change count, yet the quiet window
        // must deliver nothing.
        pasteboard.clearContents()
        pasteboard.setString("after-stop", forType: .string)
        let deliveredAfterStop = spinMainRunLoop(
            until: { received.count > deliveredAtStop },
            timeout: 0.5
        )
        #expect(!deliveredAfterStop)
        #expect(received.count == deliveredAtStop)
    }

    // MARK: - Concealed 5 MiB text (05 §6.1; 03a §4)

    /// A declared concealment marker prevents the adjacent 5 MiB payload
    /// from entering the frozen capture. The exact accessor-zero proof lives
    /// in PasteboardAdapterTests; this fixture locks the resulting value shape.
    @Test func concealedFiveMegabyteTextProducesUnreadOutcome() throws {
        let textBytes = Data(try FixtureCatalog.text("text/lorem-5mb.txt").utf8)
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setData(textBytes, forType: .string)
        pasteboard.setData(
            Data("marker".utf8),
            forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        )

        let adapter = PasteboardAdapter(pasteboard: pasteboard)
        let outcome = try #require(adapter.captureOutcome())
        guard case let .concealed(value) = outcome else {
            Issue.record("concealed marker must produce the closed concealed case")
            return
        }
        #expect(value.markerTypeIdentifier == "org.nspasteboard.ConcealedType")
        #expect(adapter.capture() == nil)
    }
}
