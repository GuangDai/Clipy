/// WS2 — Copy Coalescing (docs/06-cross-cutting.md §8 WS2): the
/// commit/receipt/storage side of submitting the same capture value a second
/// time through the public `SwiftDataHistory.perform(.capture(_:))` and the
/// real dedup/coalesce commit path.
///
/// Phasing (docs/roadmap/README.md §3, WS-clause phasing note): WS2's
/// public-read clauses defer to step 7; the occurrence-count and
/// no-second-row clauses are asserted here through the INDEPENDENT second
/// `ModelContainer` over the same on-disk store (see `WSSupport`), and the
/// `.coalesced` receipt/position side is asserted directly.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS2CopyCoalescingTests {

/// WS2 (docs/06-cross-cutting.md §8): re-capturing the same value (later
/// `observedAt`, different source) coalesces into the existing item — same
/// History Item ID and Content Version, occurrence folded (count 2, monotone
/// last-copied time, new last source) — commits Change Position 2, and
/// persists no second row.
@Test func sameCaptureAgainCoalescesIntoOneRowAndAdvancesPosition() async throws {
    let storeURL = WSSupport.tempStoreURL("ws2-copy-coalescing")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Identical bytes under the identical type identifier both times (the
    // byte-exact confirmation behind Copy Coalescing, docs/02-domain.md D7);
    // only the observation time and source differ.
    let text = "clipy coalescing probe"
    let firstObservedAt = Date(timeIntervalSinceReferenceDate: 700_000_100)
    let secondObservedAt = Date(timeIntervalSinceReferenceDate: 700_000_220)
    let firstSource = "com.example.ws2.first"
    let secondSource = "com.example.ws2.second"

    // Arrange: the initial insert (the WS1 path this gate builds on).
    let insertReceipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: firstObservedAt, source: firstSource)
    ))
    guard case let .committed(insertCommit) = insertReceipt,
          case let .inserted(insertedReference) = insertCommit.outcome
    else {
        Issue.record("WS2 arrange: expected .committed(.inserted), got \(insertReceipt)")
        return
    }

    // Act: submit the same capture value again, later observedAt, new source.
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: secondObservedAt, source: secondSource)
    ))

    // WS2: the repeat capture is a History Commit carrying `.coalesced`.
    guard case let .committed(commit) = receipt else {
        Issue.record("WS2: expected a .committed receipt, got \(receipt)")
        return
    }
    // WS2: "Change Position 2" — coalescing is a durable mutation and advances
    // the position once.
    #expect(commit.position.rawValue == 2)
    guard case let .coalesced(reference) = commit.outcome else {
        Issue.record("WS2: expected .coalesced(reference), got \(commit.outcome)")
        return
    }
    // WS2: "the same History Item ID and Content Version" — Copy Coalescing
    // preserves the winner's identity and Effective Content state
    // (docs/02-domain.md §13).
    #expect(reference.id == insertedReference.id)
    #expect(reference.contentVersion == insertedReference.contentVersion)
    #expect(reference.contentVersion.rawValue == 1)

    // Storage side, through the INDEPENDENT container.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    // WS2: "no second row" — still exactly one retained item.
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == reference.id.rawValue)
    // Coalescing never mints a Content Version (docs/02-domain.md D2, §13).
    #expect(row.contentVersionRaw == 1)

    // WS2: "occurrence count 2, monotone last-copied time" — the repeat
    // observation folds into the stored occurrence summary: the first
    // observation is untouched, the last moves forward to the later date,
    // and the last source becomes the new source while the first source is
    // preserved (docs/05-authority-kernel.md §9 occurrence folding).
    #expect(row.copyCount == 2)
    #expect(row.firstCopiedAt == firstObservedAt)
    #expect(row.lastCopiedAt == secondObservedAt)
    #expect(row.firstSource == firstSource)
    #expect(row.lastSource == secondSource)

    // Canonical Content is preserved byte-exactly by coalescing
    // (docs/02-domain.md D2): the stored blob still decodes to the original
    // capture bytes.
    let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
    #expect(canonical.representations.map(\.content.typeIdentifier) == ["public.utf8-plain-text"])
    #expect(canonical.representations.map(\.content.bytes) == [Data(text.utf8)])

    // WS2: the durable singleton matches the receipt's position.
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 2)
}
}
