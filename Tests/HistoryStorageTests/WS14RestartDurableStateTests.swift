import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

/// WS14 post-restart verification, split from
/// WS14RestartReconstructionTests.swift (file-size hygiene): the body below
/// moved verbatim; the scenario facts it reads are packaged by the test.
internal struct WS14ScenarioFacts {
    let storeURL: URL
    let restartedHistory: SwiftDataHistory
    let preRestartCommitCount: UInt64
    let idA: HistoryItemID
    let idB: HistoryItemID
    let idC: HistoryItemID
    let referenceB: HistoryItemReference
    let referenceC: HistoryItemReference
    let secondRevision: HistoryItemReference
    let textA: String
    let textB: String
    let textC: String
    let replacementOne: String
    let replacementTwo: String
    let plainText: String
    let firstCopyA: Date
    let secondCopyA: Date
    let copyB: Date
    let copyC: Date
    let postRestartCopyA: Date
    let sourceA1: String
    let sourceA2: String
    let sourceB: String
    let sourceC: String
    let sourceA3: String
}

extension WS14RestartReconstructionTests {
    /// WS14 (i)–(iv): asserts the restarted durable rows, singleton position,
    /// projection/lineage decodes, pin order, and the rebuilt Signature Index
    /// against the pre-restart scenario receipts. Verbatim relocation of the
    /// original in-test verification block; every expectation and message is
    /// unchanged.
    internal static func assertRestartedDurableState(
        _ facts: WS14ScenarioFacts
    ) async throws {
        let storeURL = facts.storeURL
        let restartedHistory = facts.restartedHistory
        let preRestartCommitCount = facts.preRestartCommitCount
        let idA = facts.idA
        let idB = facts.idB
        let idC = facts.idC
        let referenceB = facts.referenceB
        let referenceC = facts.referenceC
        let secondRevision = facts.secondRevision
        let textA = facts.textA
        let textB = facts.textB
        let textC = facts.textC
        let replacementOne = facts.replacementOne
        let replacementTwo = facts.replacementTwo
        let plainText = facts.plainText
        let firstCopyA = facts.firstCopyA
        let secondCopyA = facts.secondCopyA
        let copyB = facts.copyB
        let copyC = facts.copyC
        let postRestartCopyA = facts.postRestartCopyA
        let sourceA1 = facts.sourceA1
        let sourceA2 = facts.sourceA2
        let sourceB = facts.sourceB
        let sourceC = facts.sourceC
        let sourceA3 = facts.sourceA3

    // ── Post-restart durable state, through the INDEPENDENT container. ──
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let rows = try WSSupport.fetchRows(container)
    #expect(
        rows.count == 3,
        "WS14 (rows): exactly the three captured items are retained"
    )
    let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    let rowA = try #require(rowsByID[idA.rawValue], "WS14 (rows): item A is retained")
    let rowB = try #require(rowsByID[idB.rawValue], "WS14 (rows): item B is retained")
    let rowC = try #require(rowsByID[idC.rawValue], "WS14 (rows): item C is retained")

    // WS14 (i): "current position" — the durable singleton equals the
    // pre-restart commit count; a restart creates no commit of its own.
    let position = try WSSupport.fetchPosition(container)
    #expect(
        position.rawValue == preRestartCommitCount,
        "WS14 (position): the durable singleton equals the pre-restart commit count"
    )

    // WS14 (ii): Content Versions match the receipt-captured pre-restart
    // values — A at the second revision's minted successor, B and C initial.
    #expect(
        rowA.contentVersionRaw == secondRevision.contentVersion.rawValue,
        "WS14 (versions): A's stored Content Version matches the pre-restart revision receipt"
    )
    #expect(
        rowB.contentVersionRaw == referenceB.contentVersion.rawValue,
        "WS14 (versions): B's stored Content Version matches the pre-restart insert receipt"
    )
    #expect(
        rowC.contentVersionRaw == referenceC.contentVersion.rawValue,
        "WS14 (versions): C's stored Content Version matches the pre-restart insert receipt"
    )

    // WS14 (ii): occurrence fields — A's coalesce fold (count 2, first/last
    // times and sources) and B/C's initial occurrences survive the restart
    // exactly (docs/05-authority-kernel.md §3.1, §9 occurrence folding).
    #expect(
        rowA.copyCount == 2,
        "WS14 (occurrences): A's repeat copy folded pre-restart"
    )
    #expect(
        rowA.firstCopiedAt == firstCopyA,
        "WS14 (occurrences): A's first copy time"
    )
    #expect(
        rowA.lastCopiedAt == secondCopyA,
        "WS14 (occurrences): A's last copy time"
    )
    #expect(
        rowA.firstSource == sourceA1,
        "WS14 (occurrences): A's first source"
    )
    #expect(
        rowA.lastSource == sourceA2,
        "WS14 (occurrences): A's last source"
    )
    #expect(
        rowB.copyCount == 1,
        "WS14 (occurrences): B was copied once"
    )
    #expect(
        rowB.firstCopiedAt == copyB,
        "WS14 (occurrences): B's first copy time"
    )
    #expect(
        rowB.lastCopiedAt == copyB,
        "WS14 (occurrences): B's last copy time"
    )
    #expect(
        rowB.firstSource == sourceB,
        "WS14 (occurrences): B's first source"
    )
    #expect(
        rowB.lastSource == sourceB,
        "WS14 (occurrences): B's last source"
    )
    #expect(
        rowC.copyCount == 1,
        "WS14 (occurrences): C was copied once"
    )
    #expect(
        rowC.firstCopiedAt == copyC,
        "WS14 (occurrences): C's first copy time"
    )
    #expect(
        rowC.lastCopiedAt == copyC,
        "WS14 (occurrences): C's last copy time"
    )
    #expect(
        rowC.firstSource == sourceC,
        "WS14 (occurrences): C's first source"
    )
    #expect(
        rowC.lastSource == sourceC,
        "WS14 (occurrences): C's last source"
    )

    // WS14 (ii): §15 projection fields — A's projection is of the SECOND
    // replacement (revision projection uses the prepared proposed Effective
    // Content, §15); B and C keep their capture-time projections; every row
    // carries the v1 projection schema version.
    let effectiveTypesA = try EffectiveTypeIdentifiersBlobCodec.decode(rowA.effectiveTypeIdentifiersBlob)
    let effectiveTypesB = try EffectiveTypeIdentifiersBlobCodec.decode(rowB.effectiveTypeIdentifiersBlob)
    let effectiveTypesC = try EffectiveTypeIdentifiersBlobCodec.decode(rowC.effectiveTypeIdentifiersBlob)
    #expect(
        rowA.projectionSchemaVersion == 1,
        "WS14 (projections): A's projection schema version is the v1 value"
    )
    #expect(
        rowA.title == replacementTwo,
        "WS14 (projections): A's title projects the active Effective Content"
    )
    #expect(
        rowA.searchBody == replacementTwo,
        "WS14 (projections): A's search body projects the active Effective Content"
    )
    #expect(
        effectiveTypesA == [plainText],
        "WS14 (projections): A's effective type identifiers"
    )
    #expect(
        rowB.projectionSchemaVersion == 1,
        "WS14 (projections): B's projection schema version is the v1 value"
    )
    #expect(
        rowB.title == textB,
        "WS14 (projections): B's title keeps the capture-time projection"
    )
    #expect(
        rowB.searchBody == textB,
        "WS14 (projections): B's search body keeps the capture-time projection"
    )
    #expect(
        effectiveTypesB == [plainText],
        "WS14 (projections): B's effective type identifiers"
    )
    #expect(
        rowC.projectionSchemaVersion == 1,
        "WS14 (projections): C's projection schema version is the v1 value"
    )
    #expect(
        rowC.title == textC,
        "WS14 (projections): C's title keeps the capture-time projection"
    )
    #expect(
        rowC.searchBody == textC,
        "WS14 (projections): C's search body keeps the capture-time projection"
    )
    #expect(
        effectiveTypesC == [plainText],
        "WS14 (projections): C's effective type identifiers"
    )

    // WS14 (ii): pin order — the [C, A, B] lane established pre-restart
    // (C→0, A→1, B→2) survives the restart, unique and exactly
    // `0 ..< pinnedCount` (D12; docs/02-domain.md §10).
    #expect(
        rowA.pinOrdinal == 1,
        "WS14 (pin order): A sits in the middle of the [C, A, B] lane"
    )
    #expect(
        rowB.pinOrdinal == 2,
        "WS14 (pin order): B is last in the [C, A, B] lane"
    )
    #expect(
        rowC.pinOrdinal == 0,
        "WS14 (pin order): C leads the [C, A, B] lane"
    )
    let storedOrdinals = rows.compactMap(\.pinOrdinal)
    #expect(
        Set(storedOrdinals).count == storedOrdinals.count,
        "WS14 (pin order): stored pin ordinals are unique (D12)"
    )
    #expect(
        Set(storedOrdinals) == Set(0 ..< storedOrdinals.count),
        "WS14 (pin order): stored pin ordinals are exactly 0 ..< pinnedCount (D12)"
    )

    // WS14 (iii): A's revision-state blob decodes (production codec,
    // docs/05-authority-kernel.md §4) to the FULL append-only list in mint
    // order — revisions are immutable and append-only in v1
    // (docs/02-domain.md §2.5 rule 5) — with the second revision active.
    // Canonical Content is untouched by the revisions (docs/02-domain.md D2).
    let canonicalA = try CanonicalBlobCodec.decode(rowA.canonicalBlob)
    #expect(
        canonicalA.representations.map(\.content.typeIdentifier) == [plainText],
        "WS14 (lineage): A's Canonical type survives revisions"
    )
    #expect(
        canonicalA.representations.map(\.content.bytes) == [Data(textA.utf8)],
        "WS14 (lineage): revisions never rewrite Canonical Content (docs/02-domain.md D2)"
    )
    let lineageA = try RevisionStateBlobCodec.decode(rowA.revisionStateBlob, canonical: canonicalA)
    #expect(
        lineageA.revisions.count == 2,
        "WS14 (lineage): the full append-only revision list survives the restart (docs/02-domain.md §2.5)"
    )
    let storedOne = try #require(
        lineageA.revisions.first,
        "WS14 (lineage): the first revision is retained"
    )
    let storedTwo = try #require(
        lineageA.revisions.last,
        "WS14 (lineage): the second revision is retained"
    )
    #expect(
        storedOne.id != storedTwo.id,
        "WS14 (lineage): revision IDs are unique within the item (docs/02-domain.md §2.5 rule 2)"
    )
    #expect(
        storedOne.createdAt <= storedTwo.createdAt,
        "WS14 (lineage): the revision list is ordered by append order (docs/02-domain.md §2.5 rule 1)"
    )
    #expect(
        lineageA.activeRevisionID == storedTwo.id,
        "WS14 (lineage): the active Revision ID names the second revision"
    )
    #expect(
        storedOne.content.representations.map(\.typeIdentifier) == [plainText],
        "WS14 (lineage): the first revision's type identifiers"
    )
    #expect(
        storedOne.content.representations.map(\.bytes) == [Data(replacementOne.utf8)],
        "WS14 (lineage): the first revision's complete snapshot is independently readable (§2.5)"
    )
    #expect(
        storedTwo.content.representations.map(\.typeIdentifier) == [plainText],
        "WS14 (lineage): the second revision's type identifiers"
    )

    // WS14 (iii): Effective Content derivation (docs/02-domain.md §2.6) —
    // with an active revision, Effective Content is that revision's complete
    // content snapshot; the active revision alone contains every byte
    // required to rebuild current Effective Content after restart (§4).
    let activeRevision = try #require(
        lineageA.revisions.first(where: { $0.id == lineageA.activeRevisionID }),
        "WS14 (effective content): the active ID names exactly one stored revision (D3)"
    )
    #expect(
        activeRevision.content.representations.map(\.bytes) == [Data(replacementTwo.utf8)],
        "WS14 (effective content): the active revision's bytes are the current Effective Content (docs/02-domain.md §2.6)"
    )

    // WS14 (iii): B and C are Canonical-state items (D3) — empty revision
    // list, nil active ID — so their Effective Content is the Canonical
    // content with fingerprints stripped (docs/02-domain.md §2.6).
    let canonicalB = try CanonicalBlobCodec.decode(rowB.canonicalBlob)
    let lineageB = try RevisionStateBlobCodec.decode(rowB.revisionStateBlob, canonical: canonicalB)
    #expect(
        lineageB.revisions.isEmpty,
        "WS14 (lineage): B has no revisions (D3)"
    )
    #expect(
        lineageB.activeRevisionID == nil,
        "WS14 (lineage): B's active Revision ID is nil (D3)"
    )
    #expect(
        canonicalB.representations.map(\.content.bytes) == [Data(textB.utf8)],
        "WS14 (effective content): B's Effective Content is its Canonical bytes (docs/02-domain.md §2.6)"
    )
    let canonicalC = try CanonicalBlobCodec.decode(rowC.canonicalBlob)
    let lineageC = try RevisionStateBlobCodec.decode(rowC.revisionStateBlob, canonical: canonicalC)
    #expect(
        lineageC.revisions.isEmpty,
        "WS14 (lineage): C has no revisions (D3)"
    )
    #expect(
        lineageC.activeRevisionID == nil,
        "WS14 (lineage): C's active Revision ID is nil (D3)"
    )
    #expect(
        canonicalC.representations.map(\.content.bytes) == [Data(textC.utf8)],
        "WS14 (effective content): C's Effective Content is its Canonical bytes (docs/02-domain.md §2.6)"
    )

    // ── WS14 (iv): the rebuilt Signature Index is COMPLETE. A post-restart
    // capture of A's CANONICAL bytes (never rewritten by the revisions,
    // §2.6) must coalesce into A — candidacy re-proven from durable
    // signature metadata at startup (§13) — not insert a duplicate row.
    let probeReceipt = try await restartedHistory.perform(.capture(
        WSSupport.textCapture(textA, observedAt: postRestartCopyA, source: sourceA3)
    ))
    guard case let .committed(probeCommit) = probeReceipt,
          case let .coalesced(probeReference) = probeCommit.outcome
    else {
        Issue.record("WS14 (rebuilt index): expected .committed(.coalesced) for A's Canonical bytes post-restart, got \(probeReceipt)")
        return
    }
    #expect(
        probeCommit.position.rawValue == preRestartCommitCount + 1,
        "WS14 (rebuilt index): the coalesce is the next History Commit after the pre-restart count"
    )
    #expect(
        probeReference.id == idA,
        "WS14 (rebuilt index): the post-restart capture coalesces into A — no duplicate item"
    )
    #expect(
        probeReference.contentVersion == secondRevision.contentVersion,
        "WS14 (rebuilt index): coalescing preserves the winner's current Content Version (docs/02-domain.md §13)"
    )

    // WS14 (iv), durable side: still exactly three rows; A's occurrence fold
    // advanced (count 3, new last time/source, first observation untouched),
    // Content Version preserved (docs/02-domain.md D2), and the singleton
    // moved exactly once.
    let verification = try WSSupport.makeContainer(storeURL: storeURL)
    let verifiedRows = try WSSupport.fetchRows(verification)
    #expect(
        verifiedRows.count == 3,
        "WS14 (rebuilt index): no duplicate row — the index mapped A's Canonical signature to A"
    )
    let verifiedRowsByID = Dictionary(uniqueKeysWithValues: verifiedRows.map { ($0.id, $0) })
    let verifiedRowA = try #require(
        verifiedRowsByID[idA.rawValue],
        "WS14 (rebuilt index): item A is retained"
    )
    #expect(
        verifiedRowA.copyCount == 3,
        "WS14 (rebuilt index): the post-restart copy folded into A"
    )
    #expect(
        verifiedRowA.firstCopiedAt == firstCopyA,
        "WS14 (rebuilt index): A's first copy time is untouched"
    )
    #expect(
        verifiedRowA.lastCopiedAt == postRestartCopyA,
        "WS14 (rebuilt index): A's last copy time advanced"
    )
    #expect(
        verifiedRowA.firstSource == sourceA1,
        "WS14 (rebuilt index): A's first source is untouched"
    )
    #expect(
        verifiedRowA.lastSource == sourceA3,
        "WS14 (rebuilt index): A's last source advanced"
    )
    #expect(
        verifiedRowA.contentVersionRaw == secondRevision.contentVersion.rawValue,
        "WS14 (rebuilt index): A's Content Version is untouched by coalescing"
    )
    let verifiedPosition = try WSSupport.fetchPosition(verification)
    #expect(
        verifiedPosition.rawValue == preRestartCommitCount + 1,
        "WS14 (rebuilt index): the durable singleton matches the probe receipt"
    )
    }
}
