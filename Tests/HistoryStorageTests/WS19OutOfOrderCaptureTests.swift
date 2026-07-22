/// WS19 — Out-of-order capture monotonicity (docs/06-cross-cutting.md §8
/// WS19): an identical capture whose `observedAt` is EARLIER than the stored
/// `lastCopiedAt` still coalesces, but the occurrence fold is monotone —
/// `lastCopiedAt` never moves backward and `lastSource` never regresses —
/// per the docs/02-domain.md §3.1 fold rules:
///
/// ```text
/// lastCopiedAt = max(existing.lastCopiedAt, incoming.observedAt)
/// lastSource   = (incoming.sourceApplication ?? existing.lastSource)
///                when incoming.observedAt >= existing.lastCopiedAt,
///                otherwise existing.lastSource
/// ```
///
/// Phasing (docs/roadmap/README.md §3, WS-clause phasing note): WS19's
/// public-read/observation clauses defer to step 7; this file closes the
/// step-5 clauses — the `.coalesced` receipt with the unchanged winner ID
/// and Content Version, the incremented occurrence count, and the monotone
/// recency/source durability as seen through the INDEPENDENT second
/// `ModelContainer` over the same on-disk store (see `WSSupport`).
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS19OutOfOrderCaptureTests {

/// WS19 (docs/06-cross-cutting.md §8): capture an item at t2 with an
/// observed source, then submit an identical capture observed at t1 < t2
/// with NO source. The winner ID and Content Version are unchanged, the
/// occurrence count increments to 2, `lastCopiedAt` stays at t2 (no backward
/// move), and `lastSource` stays at the stored source (no regression to nil).
@Test func outOfOrderCaptureCoalescesWithoutMovingRecencyOrSourceBackward() async throws {
    let storeURL = WSSupport.tempStoreURL("ws19-out-of-order-capture")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let text = "clipy out-of-order probe"
    // t1 < t2: the repeat observation arrives OUT OF ORDER.
    let earlierObservedAt = Date(timeIntervalSinceReferenceDate: 700_020_100) // t1
    let laterObservedAt = Date(timeIntervalSinceReferenceDate: 700_020_900) // t2
    let source = "com.example.ws19.newer"

    // Arrange: the item is first captured at the LATER time t2 with an
    // observed source, so the stored occurrence starts with
    // lastCopiedAt = t2 and lastSource = source.
    let insertReceipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: laterObservedAt, source: source)
    ))
    guard case let .committed(insertCommit) = insertReceipt,
          case let .inserted(insertedReference) = insertCommit.outcome
    else {
        Issue.record("WS19 arrange: expected .committed(.inserted), got \(insertReceipt)")
        return
    }

    // Act: the identical capture value arrives observed at t1 < t2, with a
    // nil source observation.
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: earlierObservedAt)
    ))

    // WS19: "the winner ID is unchanged" — the repeat is a `.coalesced`
    // History Commit naming the same item at its preserved Content Version
    // (docs/02-domain.md §13), advancing Change Position once.
    guard case let .committed(commit) = receipt else {
        Issue.record("WS19: expected a .committed receipt, got \(receipt)")
        return
    }
    #expect(commit.position.rawValue == 2)
    guard case let .coalesced(reference) = commit.outcome else {
        Issue.record("WS19: expected .coalesced(reference), got \(commit.outcome)")
        return
    }
    #expect(reference.id == insertedReference.id)
    #expect(reference.contentVersion == insertedReference.contentVersion)
    #expect(reference.contentVersion.rawValue == 1)

    // Storage side, through the INDEPENDENT container: no second row.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == reference.id.rawValue)
    #expect(row.contentVersionRaw == 1)

    // WS19: "occurrence `count` increments" — the out-of-order copy still
    // folds into the occurrence summary (docs/02-domain.md §3.1).
    #expect(row.copyCount == 2)
    // WS19: "`lastCopiedAt` does not move backward" — the fold's
    // max(existing, incoming) keeps t2 (docs/02-domain.md §3.1: "Out-of-order
    // capture must not move recency … backwards").
    #expect(row.lastCopiedAt == laterObservedAt)
    #expect(row.firstCopiedAt == laterObservedAt)
    // WS19: "`lastSource` does not regress to nil" — the
    // `incoming ?? existing` update applies only when the incoming
    // observation is at least as recent as the stored `lastCopiedAt`; here
    // t1 < t2, so the stored source survives (docs/02-domain.md §3.1).
    #expect(row.lastSource == source)
    #expect(row.firstSource == source)

    // Canonical Content is untouched by the fold (docs/02-domain.md D2).
    let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
    #expect(canonical.representations.map(\.content.typeIdentifier) == ["public.utf8-plain-text"])
    #expect(canonical.representations.map(\.content.bytes) == [Data(text.utf8)])

    // The durable singleton matches the receipt's position.
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 2)
}

/// WS19 companion (docs/02-domain.md §3.1): an out-of-order capture carrying
/// its OWN non-nil source still cannot rewrite `lastSource` — the
/// "otherwise `existing.lastSource`" branch keeps the newer observation's
/// source, proving the guard is the observation-time comparison and not the
/// nil-coalescing alone.
@Test func outOfOrderCaptureWithSourceKeepsExistingLastSource() async throws {
    let storeURL = WSSupport.tempStoreURL("ws19-out-of-order-source")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let text = "clipy out-of-order source probe"
    let earlierObservedAt = Date(timeIntervalSinceReferenceDate: 700_021_100) // t1
    let laterObservedAt = Date(timeIntervalSinceReferenceDate: 700_021_900) // t2
    let newerSource = "com.example.ws19.newer"
    let staleSource = "com.example.ws19.stale"

    // Arrange: insert at the LATER time t2 with the newer source.
    let insertReceipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: laterObservedAt, source: newerSource)
    ))
    guard case let .committed(insertCommit) = insertReceipt,
          case let .inserted(insertedReference) = insertCommit.outcome
    else {
        Issue.record("WS19 arrange: expected .committed(.inserted), got \(insertReceipt)")
        return
    }

    // Act: the identical capture arrives at t1 < t2 carrying a DIFFERENT
    // non-nil source.
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: earlierObservedAt, source: staleSource)
    ))

    guard case let .committed(commit) = receipt else {
        Issue.record("WS19: expected a .committed receipt, got \(receipt)")
        return
    }
    #expect(commit.position.rawValue == 2)
    guard case let .coalesced(reference) = commit.outcome else {
        Issue.record("WS19: expected .coalesced(reference), got \(commit.outcome)")
        return
    }
    #expect(reference.id == insertedReference.id)
    #expect(reference.contentVersion.rawValue == 1)

    // Storage side, through the INDEPENDENT container.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == reference.id.rawValue)

    // docs/02-domain.md §3.1: the count still increments and recency stays
    // monotone …
    #expect(row.copyCount == 2)
    #expect(row.lastCopiedAt == laterObservedAt)
    #expect(row.firstCopiedAt == laterObservedAt)
    // … and the out-of-order guard keeps the EXISTING last source: the stale
    // observation's source is dropped ("otherwise existing.lastSource"), so
    // its associated source observation never moves backwards either.
    #expect(row.lastSource == newerSource)
    #expect(row.firstSource == newerSource)

    // The durable singleton matches the receipt's position.
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 2)
}
}
