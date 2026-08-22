/// PLAY-TIER-2A-THUMB — current-layout thumbnail source accounting.
///
/// The existing Authority source lane still hydrates the complete monolithic
/// Canonical/revision lineage. Its caller receives only the selected image
/// representation, while the content-free receipt keeps that returned value
/// separate from the encoded aggregates accessed to select it. This is not an
/// RSS measurement or physical single-representation I/O proof.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Test func thumbnailSourceReturnsOnlySelectedImageAndAccountsWholeEncodedAggregates() async throws {
    let storeURL = WSSupport.tempStoreURL("thumbnail-aggregate-hydration")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // Literal valid 1 x 1 transparent PNG plus a much larger unrelated
    // Effective-Content representation. The PNG is the thumbnail source; the
    // text proves the returned representation is not the hydrated aggregate.
    let selectedPNG = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    ))
    let unrelatedText = String(repeating: "U", count: 8_192)
    let captureReceipt = try await history.perform(.capture(
        WSSupport.textCapture(
            "canonical seed",
            observedAt: Date(timeIntervalSinceReferenceDate: 700_090_000),
            source: "com.example.play-tier-2a-thumb",
            extra: [(typeIdentifier: "public.png", bytes: [UInt8](selectedPNG))]
        )
    ))
    guard case let .committed(commit) = captureReceipt,
          case let .inserted(canonicalReference) = commit.outcome
    else {
        Issue.record("PLAY-TIER-2A-THUMB arrange: expected committed insertion")
        return
    }

    // Make the large unrelated value current through a full-snapshot
    // revision. This ensures both stored aggregates contain behavior-bearing
    // fixture data while the selected PNG remains byte-exact Canonical data.
    let revisionReceipt = try await history.perform(.revise(RevisionRequest(
        itemID: canonicalReference.id,
        expected: canonicalReference.contentVersion,
        intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(
                typeIdentifier: "public.png",
                action: .inheritCanonical
            ),
            RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: Data(unrelatedText.utf8))
            ),
        ]))
    )))
    guard case let .committed(revisionCommit) = revisionReceipt,
          case let .revised(reference) = revisionCommit.outcome
    else {
        Issue.record("PLAY-TIER-2A-THUMB arrange: expected committed revision")
        return
    }

    // The independent read-only container is the oracle for the exact encoded
    // aggregates the current source lane accesses. It does not reproduce the
    // production accounting formula from decoded payloads.
    let assertionContainer = try WSSupport.makeContainer(storeURL: storeURL)
    let assertionContext = ModelContext(assertionContainer)
    let id = reference.id.rawValue
    var descriptor = FetchDescriptor<HistoryItemRow>(
        predicate: #Predicate { row in row.id == id }
    )
    descriptor.fetchLimit = 2
    let rows = try assertionContext.fetch(descriptor)
    let row = try #require(rows.count == 1 ? rows[0] : nil)
    let (expectedAggregateBytes, aggregateOverflow) = row.canonicalBlob.count
        .addingReportingOverflow(row.revisionStateBlob.count)
    try #require(!aggregateOverflow)

    let positionBefore = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: 1)
    ).position
    let selection = try #require(try await history.authority.thumbnailSource(
        for: reference,
        pixels: PixelSize(width: 32, height: 32)
    ))

    #expect(selection.bytes == selectedPNG)
    #expect(selection.receipt.returnedRepresentationBytes == selectedPNG.count)
    #expect(selection.receipt.aggregateHydratedBytes == expectedAggregateBytes)
    #expect(
        selection.receipt.aggregateHydratedBytes
            > selection.receipt.returnedRepresentationBytes
    )

    // A source read is not a History Commit and does not advance coherence.
    let positionAfter = try await history.browse(
        HistoryBrowseRequest(kind: .recent, limit: 1)
    ).position
    #expect(positionAfter == positionBefore)
}
