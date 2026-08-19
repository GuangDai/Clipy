/// WS19Composed — Out-of-order capture monotonicity through the composed
/// app stack (docs/06-cross-cutting.md §8 WS19; docs/02-domain.md §3.1
/// occurrence fold; 05 §9): an identical capture whose `observedAt` is
/// EARLIER than the stored `lastCopiedAt` still folds — the winner ID is
/// unchanged, occurrence count increments, `lastCopiedAt` does not move
/// backward, and `lastSource` does not regress to nil when the newer copy
/// carried no observed source.
///
/// Built as direct captures with fixed origins: the adapter's live
/// `NSWorkspace` source observation is non-deterministic in a hosted test,
/// while the out-of-order OBSERVED-AT clock is precisely the input the gate
/// controls (the adapter accepts `observedAt:`; origin fields are the
/// observation under test, and the app-level monotonicity contract is the
/// storage fold either way).
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct WS19ComposedOutOfOrderCaptureTests {

    /// WS19 (docs/06-cross-cutting.md §8): capture at T0 (with source),
    /// then an identical capture observed EARLIER (T0−100) with NO source:
    /// count increments to 2, `lastCopiedAt` stays at T0 (monotone),
    /// `lastSource` keeps the observed value (no nil regression), and the
    /// winner ID never changes.
    @Test
    func earlierObservedIdenticalCaptureFoldsWithoutRegressingOccurrence() async throws {
        let history = try await ComposedSupport.openMemoryHistory()

        let text = "ws19 composed monotone probe"
        let firstObservedAt = Date(timeIntervalSinceReferenceDate: 700_202_700)
        let earlierObservedAt = firstObservedAt.addingTimeInterval(-100)
        let source = "com.example.ws19composed"

        let firstReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                text, observedAt: firstObservedAt, source: source
            )
        ))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: firstReceipt, "WS19 arrange")
        )

        // The out-of-order observation: identical bytes, earlier clock, no
        // observed source (the `lastSource ?? existing.lastSource` rule,
        // 05 §9 fold).
        let outOfOrderReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(text, observedAt: earlierObservedAt, source: nil)
        ))
        let coalesced = try #require(
            ComposedSupport.coalescedReference(from: outOfOrderReceipt, "WS19 fold")
        )
        #expect(
            coalesced.id == inserted.id,
            "WS19: the winner ID is unchanged by the out-of-order copy"
        )
        #expect(
            coalesced.contentVersion == inserted.contentVersion,
            "WS19: no Content Version is minted"
        )

        // The occurrence summary (03b §9): count 2, monotone lastCopiedAt,
        // no nil regression, first observation untouched.
        let details = try await history.details(for: inserted.id)
        #expect(details.occurrence.count == 2, "WS19: the occurrence increments")
        #expect(
            details.occurrence.lastCopiedAt == firstObservedAt,
            "WS19: lastCopiedAt does not move backward"
        )
        #expect(details.occurrence.firstCopiedAt == earlierObservedAt)
        #expect(
            details.occurrence.lastSource == source,
            "WS19 (05 §9): lastSource does not regress to nil"
        )
        #expect(details.occurrence.firstSource == nil)

        // The composed rows reflect the fold exactly once.
        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 50)
        )
        #expect(page.rows.count == 1)
        #expect(page.rows.first?.copyCount == 2)
        #expect(page.rows.first?.lastCopiedAt == firstObservedAt)
    }
}
