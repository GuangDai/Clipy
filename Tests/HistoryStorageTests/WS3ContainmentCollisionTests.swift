/// WS3 — Rich-to-plain containment and collision safety
/// (docs/06-cross-cutting.md §8 WS3), plus the two §7.6 signature proofs:
/// a forced xxh3 collision still requires byte confirmation, and startup
/// Signature Index postings cover every retained Canonical signature entry
/// (docs/06-cross-cutting.md §7.6; docs/02-domain.md §9.1–§9.2, D7).
///
/// Phasing (docs/roadmap/README.md §3, WS-clause phasing note): WS3's public
/// read/observation clauses defer to step 7; this file closes the step-5
/// clauses — the `.coalesced` receipt into the richer Canonical item, the
/// no-second-row storage proof through the INDEPENDENT second
/// `ModelContainer` over the same on-disk store (see `WSSupport`), and the
/// two §7.6 proofs.
///
/// Part 2 drives `IngestPreparationActor` + `HistoryAuthority` directly
/// (storage side) because the public facade always constructs its own
/// preparation actor with the real xxh3-64 fingerprint — there is no public
/// seam to substitute the deterministic collision double. The spec permits
/// exactly this: docs/01-architecture.md §4 allows a package-only
/// deterministic collision double in Domain/Storage tests, and the test
/// performs the same `prepare` → `commitCapture` sequence the facade
/// performs (docs/05-authority-kernel.md §6.1, §9). Parts 1 and 3 cross the
/// public `ClipboardHistory` interface only (docs/06-cross-cutting.md §8).
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

struct WS3ContainmentCollisionTests {

/// Part 1 — WS3 containment (docs/06-cross-cutting.md §8 WS3): inserting
/// rich+plain content and then submitting the matching plain-only capture
/// coalesces into the richer Canonical item — same History Item ID and
/// Content Version, the occurrence folded, Change Position advanced once —
/// and persists no second row while the retained Canonical Content stays the
/// richer byte-exact set.
@Test func plainOnlyCaptureCoalescesIntoRicherCanonicalItem() async throws {
    let storeURL = WSSupport.tempStoreURL("ws3-containment")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Rich+plain capture: one plain-text representation plus one public.html
    // representation of the same copied text, fixed observation time/source.
    let text = "clipy rich containment probe"
    let html = "<p>clipy rich containment probe</p>"
    let richObservedAt = Date(timeIntervalSinceReferenceDate: 700_001_000)
    let plainObservedAt = Date(timeIntervalSinceReferenceDate: 700_001_500)
    let richSource = "com.example.ws3.rich"
    let plainSource = "com.example.ws3.plain"

    // Arrange: insert the rich+plain item through the public facade.
    let insertReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            text,
            observedAt: richObservedAt,
            source: richSource,
            extra: [(typeIdentifier: "public.html", bytes: [UInt8](html.utf8))]
        )
    ))
    guard case let .committed(insertCommit) = insertReceipt,
          case let .inserted(insertedReference) = insertCommit.outcome
    else {
        Issue.record("WS3 arrange: expected .committed(.inserted), got \(insertReceipt)")
        return
    }

    // Act: submit the matching plain-ONLY capture — the identical plain-text
    // bytes under the identical type identifier, nothing else. Every incoming
    // (typeIdentifier, bytes) pair appears in the retained Canonical set, so
    // byte-exact containment confirms the coalesce (docs/02-domain.md §9.2).
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: plainObservedAt, source: plainSource)
    ))

    // WS3: the plain-only capture is a History Commit carrying `.coalesced`.
    guard case let .committed(commit) = receipt else {
        Issue.record("WS3: expected a .committed receipt, got \(receipt)")
        return
    }
    // WS3: coalescing is a durable mutation — Change Position advances once.
    #expect(commit.position.rawValue == 2)
    guard case let .coalesced(reference) = commit.outcome else {
        Issue.record("WS3: expected .coalesced(reference), got \(commit.outcome)")
        return
    }
    // WS3: "coalescing into the richer Canonical item" — the winner is the
    // rich item, with its Content Version preserved (docs/02-domain.md §13).
    #expect(reference.id == insertedReference.id)
    #expect(reference.contentVersion == insertedReference.contentVersion)
    #expect(reference.contentVersion.rawValue == 1)

    // Storage side, through the INDEPENDENT container.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    // WS3: still one row — containment absorbed the plain-only copy.
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == reference.id.rawValue)
    #expect(row.contentVersionRaw == 1)

    // The occurrence folded: count 2, first observation untouched, last
    // copied time/source moved to the plain-only observation
    // (docs/05-authority-kernel.md §9 occurrence folding).
    #expect(row.copyCount == 2)
    #expect(row.firstCopiedAt == richObservedAt)
    #expect(row.lastCopiedAt == plainObservedAt)
    #expect(row.firstSource == richSource)
    #expect(row.lastSource == plainSource)

    // WS3: the retained Canonical is still the RICHER set — both
    // representations, byte-exact, in normalized order ("public.html" sorts
    // before "public.utf8-plain-text" in Unicode scalar order,
    // docs/02-domain.md §2.1). Coalescing never rewrites Canonical Content
    // (docs/02-domain.md D2).
    let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
    #expect(
        canonical.representations.map(\.content.typeIdentifier)
            == ["public.html", "public.utf8-plain-text"]
    )
    #expect(
        canonical.representations.map(\.content.bytes)
            == [Data(html.utf8), Data(text.utf8)]
    )

    // WS3: the durable singleton matches the receipt's position.
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 2)
}

/// Part 2 — §7.6 forced collision (docs/06-cross-cutting.md §7.6;
/// docs/02-domain.md D7): two captures with DIFFERENT bytes but forced-equal
/// fingerprints produce TWO distinct items — byte confirmation rejects the
/// false match. Storage-side proof: `IngestPreparationActor` with the
/// `ForcedCollisionFingerprint` double plus a direct `HistoryAuthority`
/// (file header documents why this part does not cross the public facade).
@Test func forcedFingerprintCollisionWithDifferentBytesInsertsNewItem() async throws {
    let storeURL = WSSupport.tempStoreURL("ws3-forced-collision")
    defer { WSSupport.removeStore(storeURL) }
    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)
    let preparation = IngestPreparationActor(
        fingerprint: ForcedCollisionFingerprint.digest(of:)
    )

    // Two captures whose plain-text bytes DIFFER but share the type
    // identifier AND byte count, so under the collision double their
    // signature entries (typeIdentifier, fingerprint, byteCount) are EQUAL:
    // the second capture's entry intersects the first item's posting set,
    // making it a dedup candidate that only byte confirmation can reject
    // (docs/02-domain.md §9.1–§9.2). Different byte counts would leave
    // candidacy empty and let this test pass without exercising the
    // confirmation step.
    let firstText = "collision witness one"
    let secondText = "collision witness two"
    #expect(Data(firstText.utf8).count == Data(secondText.utf8).count)
    #expect(Data(firstText.utf8) != Data(secondText.utf8))

    // Arrange: insert the first capture storage-side, exactly as the facade
    // would (prepare off the Authority, then commit).
    let firstBundle = try await preparation.prepare(
        WSSupport.textCapture(
            firstText,
            observedAt: Date(timeIntervalSinceReferenceDate: 700_002_000),
            source: "com.example.ws3.collision.first"
        )
    )
    let firstReceipt = try await authority.commitCapture(firstBundle)
    guard case let .committed(firstCommit) = firstReceipt,
          case let .inserted(firstReference) = firstCommit.outcome
    else {
        Issue.record("§7.6 arrange: expected .committed(.inserted), got \(firstReceipt)")
        return
    }

    // Act: prepare and commit the colliding second capture.
    let secondBundle = try await preparation.prepare(
        WSSupport.textCapture(
            secondText,
            observedAt: Date(timeIntervalSinceReferenceDate: 700_002_500),
            source: "com.example.ws3.collision.second"
        )
    )
    let secondReceipt = try await authority.commitCapture(secondBundle)

    guard case let .committed(secondCommit) = secondReceipt else {
        Issue.record("§7.6: expected a .committed receipt, got \(secondReceipt)")
        return
    }
    // §7.6: the rejected false match still commits — as an INSERT.
    #expect(secondCommit.position.rawValue == 2)
    guard case let .inserted(secondReference) = secondCommit.outcome else {
        Issue.record(
            "§7.6: expected .inserted(reference) — byte confirmation must reject a forced fingerprint collision — got \(secondCommit.outcome)"
        )
        return
    }
    // §7.6 / D7: equal fingerprints did NOT coalesce — a new, distinct item.
    #expect(secondReference.id != firstReference.id)
    #expect(secondReference.contentVersion.rawValue == 1)

    // Storage side, through the INDEPENDENT container: TWO distinct rows.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    // §7.6: "forced xxh3 collision still requires byte confirmation" — the
    // collision produced a candidate, confirmation rejected it, and both
    // items are retained.
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.id)) == Set([firstReference.id.rawValue, secondReference.id.rawValue]))

    for row in rows {
        // Each row is an independent first copy at the initial version.
        #expect(row.copyCount == 1)
        #expect(row.contentVersionRaw == 1)
        // Each row retains its OWN distinct bytes under the plain-text type.
        let expectedText = row.id == firstReference.id.rawValue ? firstText : secondText
        let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
        #expect(canonical.representations.map(\.content.typeIdentifier) == ["public.utf8-plain-text"])
        #expect(canonical.representations.map(\.content.bytes) == [Data(expectedText.utf8)])
    }

    // Prove the collision was genuinely in force — the test is not vacuous:
    // both rows' durable signature entries are EQUAL (same type identifier,
    // same forced fingerprint, same byte count), so the second capture's
    // candidacy provably contained the first item before byte confirmation.
    let signatureEntries = try rows.map { try SignatureBlobCodec.decode($0.canonicalSignatureBlob) }
    #expect(signatureEntries.count == 2)
    #expect(signatureEntries[0] == signatureEntries[1])
    #expect(signatureEntries[0].map(\.fingerprint.rawValue) == [ForcedCollisionFingerprint.collisionValue])
    #expect(signatureEntries[0].map(\.byteCount) == [Data(firstText.utf8).count])

    // §7.6: the durable singleton matches the second receipt's position.
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 2)
}

/// Part 3 — §7.6 startup completeness, behavioral
/// (docs/06-cross-cutting.md §7.6): the rich item is inserted through the
/// public facade, the facade is dropped, and `SwiftDataHistory` is REOPENED
/// on the same store — startup rebuilds the Signature Index from the stored
/// signature blobs (docs/05-authority-kernel.md §13 step 8). Submitting the
/// matching plain-only capture again still coalesces into the original item,
/// proving the rebuilt postings cover the retained signature entries.
@Test func reopenedHistoryCoalescesPlainOnlyCaptureIntoRetainedRichItem() async throws {
    let storeURL = WSSupport.tempStoreURL("ws3-startup-completeness")
    defer { WSSupport.removeStore(storeURL) }

    let text = "clipy restart containment probe"
    let html = "<p>clipy restart containment probe</p>"
    let richObservedAt = Date(timeIntervalSinceReferenceDate: 700_003_000)
    let plainObservedAt = Date(timeIntervalSinceReferenceDate: 700_003_500)
    let richSource = "com.example.ws3.restart.rich"
    let plainSource = "com.example.ws3.restart.plain"

    // Arrange: insert the rich+plain item, then DROP the facade so the
    // reopened history starts with an empty in-memory Signature Index.
    let insertedReference: HistoryItemReference
    do {
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                text,
                observedAt: richObservedAt,
                source: richSource,
                extra: [(typeIdentifier: "public.html", bytes: [UInt8](html.utf8))]
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome
        else {
            Issue.record("§7.6 arrange: expected .committed(.inserted), got \(receipt)")
            return
        }
        insertedReference = reference
    }

    // Act: REOPEN on the same store (§13 startup rebuilds postings from
    // durable signature blobs — no content bytes are decoded) and submit the
    // matching plain-only capture through the new facade.
    let reopened = try await WSSupport.openHistory(storeURL: storeURL)
    let receipt = try await reopened.perform(.capture(
        WSSupport.textCapture(text, observedAt: plainObservedAt, source: plainSource)
    ))

    guard case let .committed(commit) = receipt else {
        Issue.record("§7.6: expected a .committed receipt, got \(receipt)")
        return
    }
    // §7.6: the coalesce is a durable mutation on the reopened store.
    #expect(commit.position.rawValue == 2)
    guard case let .coalesced(reference) = commit.outcome else {
        Issue.record(
            "§7.6: expected .coalesced(reference) — rebuilt startup postings must cover the retained signature entries — got \(commit.outcome)"
        )
        return
    }
    // §7.6: "startup postings cover every retained Canonical signature
    // entry" — the rebuilt index found the rich item as a containment
    // candidate and byte confirmation coalesced into the ORIGINAL item.
    #expect(reference.id == insertedReference.id)
    #expect(reference.contentVersion == insertedReference.contentVersion)
    #expect(reference.contentVersion.rawValue == 1)

    // Storage side, through the INDEPENDENT container: still one row, the
    // occurrence folded, and the richer Canonical set intact.
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.id == reference.id.rawValue)
    #expect(row.contentVersionRaw == 1)
    #expect(row.copyCount == 2)
    #expect(row.firstCopiedAt == richObservedAt)
    #expect(row.lastCopiedAt == plainObservedAt)

    let canonical = try CanonicalBlobCodec.decode(row.canonicalBlob)
    #expect(
        canonical.representations.map(\.content.typeIdentifier)
            == ["public.html", "public.utf8-plain-text"]
    )
    #expect(
        canonical.representations.map(\.content.bytes)
            == [Data(html.utf8), Data(text.utf8)]
    )

    // §7.6: the durable singleton matches the receipt's position.
    let position = try WSSupport.fetchPosition(container)
    #expect(position.rawValue == 2)
}
}
