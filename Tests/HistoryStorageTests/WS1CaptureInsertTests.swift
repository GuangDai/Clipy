/// WS1 — Raw capture insert (docs/06-cross-cutting.md §8 WS1): the
/// commit/receipt/storage side of submitting a normalized raw text capture to
/// an empty store through the public `SwiftDataHistory.perform(.capture(_:))`
/// and the real `HistoryAuthority` commit path.
///
/// Phasing (docs/roadmap/README.md §3, WS-clause phasing note): WS1's
/// observed-page clause is a step-7 (reads + observation) clause and is NOT
/// asserted here; this file closes the step-5 clauses — the `.committed`
/// receipt with `.inserted(reference)`, the initial Content Version, Change
/// Position 1, and the durable row/singleton state as seen through an
/// INDEPENDENT second `ModelContainer` over the same on-disk store (see
/// `WSSupport`).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS1CaptureInsertTests {

/// WS1 (docs/06-cross-cutting.md §8): one raw text capture on an empty store
/// commits once, returns `.inserted(reference)` at the initial Content
/// Version and Change Position 1, and persists exactly one row carrying the
/// full Canonical bytes plus the correct initial occurrence/projection, with
/// the position singleton at 1.
@Test func rawTextCaptureInsertsOneRowAtInitialVersionAndPosition() async throws {
    let storeURL = WSSupport.tempStoreURL("ws1-capture-insert")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // A normalized raw text capture (§8 WS1): one public.utf8-plain-text
    // representation, fixed observation time, one observed source. Single-line
    // text keeps the §15 projection deterministic (title == body == text).
    let text = "clipy walking skeleton"
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let source = "com.example.ws1"

    let receipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: observedAt, source: source)
    ))

    // WS1: the capture is a History Commit (not `.unchanged`).
    guard case let .committed(commit) = receipt else {
        Issue.record("WS1: expected a .committed receipt, got \(receipt)")
        return
    }
    // WS1: Change Position 1 — the first commit moves the singleton 0 → 1
    // (docs/05-authority-kernel.md §3.2).
    #expect(commit.position.rawValue == 1)
    // WS1: `.inserted(reference)` for a new item on an empty store.
    guard case let .inserted(reference) = commit.outcome else {
        Issue.record("WS1: expected .inserted(reference), got \(commit.outcome)")
        return
    }
    // WS1: Content Version 1 — the reference names the initial Effective
    // Content state (docs/02-domain.md: versions start at 1).
    #expect(reference.contentVersion.rawValue == 1)

    // Storage side, through the INDEPENDENT container (no production test
    // seam): exactly one durable row.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    // WS1: "Expect one row".
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    // The row is the receipt's item, at the same initial Content Version.
    #expect(row.id == reference.id.rawValue)
    #expect(row.contentVersionRaw == 1)

    // WS1: "full Canonical bytes" — the stored Canonical blob decodes to the
    // exact capture bytes under the exact type identifier.
    let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
    #expect(canonical.representations.map(\.content.typeIdentifier) == ["public.utf8-plain-text"])
    #expect(canonical.representations.map(\.content.bytes) == [Data(text.utf8)])

    // WS1: "correct initial occurrence" — first and last observation both
    // equal `observedAt`, count 1, and the observed source is both first and
    // last (docs/05-authority-kernel.md §9 create-stamping).
    #expect(row.firstCopiedAt == observedAt)
    #expect(row.lastCopiedAt == observedAt)
    #expect(row.copyCount == 1)
    #expect(row.firstSource == source)
    #expect(row.lastSource == source)

    // WS1: "correct initial … projection" — the §15 durable projection of the
    // Canonical-as-Effective content, written with the item at schema
    // version 1, and the item starts unpinned (`nil` ordinal, §3.1).
    #expect(row.projectionSchemaVersion == 1)
    #expect(row.title == text)
    #expect(row.searchBody == text)
    #expect(
        try EffectiveTypeIdentifiersBlobCodec.decode(row.effectiveTypeIdentifiersBlob)
            == ["public.utf8-plain-text"]
    )
    #expect(row.pinOrdinal == nil)

    // WS1: "Change Position 1" — the durable singleton matches the receipt's
    // position (one transaction, docs/06-cross-cutting.md §7.1).
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 1)
}
}
