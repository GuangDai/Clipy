/// WS5Composed — Capture-path rejection through the composed app stack
/// (docs/06-cross-cutting.md §8 WS5; docs/05-authority-kernel.md §6.1;
/// docs/01-architecture.md §5.1 capture loop): the composed essence of the
/// "candidate proof unavailable" gate. A concealed pasteboard marker
/// freezes into `isConcealed == true`, storage rejects the WHOLE capture
/// with `.invalidInput(.excludedFromHistory)` before fingerprinting
/// (defense in depth), and NOTHING durable happens — no row, no position
/// advance, no observation disturbance. Production short-circuits the
/// explicit concealed outcome before History; this test separately retains
/// the Storage rejection as defense-in-depth evidence.
///
/// The gate's Signature-Index-rebuild clause — forcing
/// `.temporarilyUnavailable(.dedupIndexRebuild)` — requires the storage-side
/// fault-injection seams and stays in
/// `Tests/HistoryStorageTests/WS5DedupIndexUnavailableTests.swift`.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import Testing

struct WS5ComposedCaptureRejectionTests {

    /// WS5 essence (docs/06-cross-cutting.md §8; 05 §6.1): a pasteboard
    /// carrying one of the six concealment markers plus sibling plaintext
    /// freezes concealed, is rejected with
    /// `.invalidInput(.excludedFromHistory)`, and produces no row and no
    /// position advance — the NEXT successful capture commits at Change
    /// Position 1, proving the rejected attempt advanced nothing.
    @Test @MainActor
    func concealedMarkerCaptureIsRejectedWithNoDurableEffect() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let history = try await ComposedSupport.openMemoryHistory()

        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        pasteboard.setData(Data("sensitive".utf8), forType: .string)
        pasteboard.setData(
            Data("marker".utf8),
            forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        )
        let adapter = PasteboardAdapter(pasteboard: pasteboard)

        // Early whole-item privacy semantics (05 §6.1): the marker is enough
        // to construct a concealed rejection value; sibling bytes remain
        // unread and therefore cannot be retained by the adapter.
        let outcome = try #require(
            adapter.captureOutcome(
                observedAt: Date(timeIntervalSinceReferenceDate: 700_200_900)
            )
        )
        let capture = outcome.capture
        #expect(!outcome.isComplete)
        #expect(capture.isConcealed == true)
        #expect(capture.representations.isEmpty)
        #expect(adapter.capture() == nil)

        do {
            _ = try await history.perform(.capture(capture))
            Issue.record(
                "WS5: expected .invalidInput(.excludedFromHistory), got a receipt"
            )
        } catch let failure as HistoryFailure {
            #expect(
                failure == .invalidInput(.excludedFromHistory),
                "WS5 (05 §6.1): the concealed capture fails closed, got \(failure)"
            )
        }

        // No row, nothing observable (04 §3: only a committed receipt
        // advances anything).
        let emptyPage = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(emptyPage.rows.isEmpty)

        // The position proof: the next successful capture is Change
        // Position 1 — the rejection advanced no position, minted no
        // receipt, and published no invalidation.
        ComposedSupport.setPasteboardContents(
            "clipy after rejection",
            on: pasteboard
        )
        let healthy = try #require(
            adapter.capture(observedAt: Date(timeIntervalSinceReferenceDate: 700_200_950))
        )
        let receipt = try await history.perform(.capture(healthy))
        let commit = try #require(
            ComposedSupport.commit(of: receipt, "WS5"),
            "WS5: the next healthy capture commits normally"
        )
        #expect(
            commit.position.rawValue == 1,
            "WS5: the rejected capture advanced no Change Position"
        )
    }

    /// WS5 companion (01 §5.1; roadmap 04): a change that leaves nothing
    /// retainable (a cleared pasteboard) yields NO capture at all — the
    /// adapter returns nil and the capture loop never submits an action,
    /// so History is never asked to reject an `.emptyCapture`.
    @Test @MainActor
    func clearedPasteboardYieldsNoCaptureAndNoAction() async throws {
        try ComposedSupport.requireUsablePasteboard()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let adapter = PasteboardAdapter(pasteboard: pasteboard)

        #expect(
            adapter.capture() == nil,
            "WS5: nothing retainable observed — no capture crosses the seam"
        )
    }
}
