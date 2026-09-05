/// Part VI §7.4 — durable scalar projection corruption fails closed at every
/// read boundary that consumes the corrupted field. These fixtures write a
/// production-codec-valid row with exactly one damaged projection scalar;
/// they do not substitute a fake history writer for semantic behavior.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

struct ProjectionCorruptionTests {

private enum Corruption: Equatable {
    case schemaVersion
    case title
    case malformedTitleUTF8
    case searchBody
    case malformedSearchBodyUTF8
    case lastCopiedAt
    case copyCount
    case lastSource
}

private static func seedRow(
    at storeURL: URL,
    corruption: Corruption
) async throws -> HistoryItemID {
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_050_000)
    let preparation = IngestPreparationActor()
    let bundle = try await preparation.prepare(
        WSSupport.textCapture(
            "projection corruption control",
            observedAt: observedAt,
            source: "com.example.projection-corruption"
        )
    )

    let schemaVersion: UInt16 = corruption == .schemaVersion
        ? ContentProjector.schemaVersion + 1
        : bundle.projection.schemaVersion
    let title = corruption == .title
        ? String(
            repeating: "t",
            count: HistoryLimits.standard.maximumStoredTitleUTF8Bytes + 1
        )
        : bundle.projection.title
    let searchBodyUTF8 = corruption == .searchBody
        ? Data(
            repeating: 0x62,
            count: HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes + 1
        )
        : Data(bundle.projection.searchBody.utf8)
    // SQLite binds NaN as SQL NULL, which would fail this non-optional column
    // before the read-path validator is exercised. Infinity remains a REAL and
    // therefore reaches the exact durable-scalar boundary under test; NaN is
    // covered directly by RevisionStateBlobCodecTests.
    let lastCopiedAt = corruption == .lastCopiedAt
        ? Date(timeIntervalSinceReferenceDate: .infinity)
        : observedAt
    let copyCount: UInt64 = corruption == .copyCount ? 0 : 1
    let lastSource = corruption == .lastSource
        ? String(
            repeating: "s",
            count: HistoryLimits.standard
                .maximumSourceApplicationObservationUTF8Bytes + 1
        )
        : "com.example.projection-corruption"

    let row = try HistoryItemRow(
        id: bundle.domain.candidateID.rawValue,
        contentVersionRaw: 1,
        canonicalBlob: CanonicalBlobCodec.encode(bundle.domain.canonical),
        revisionStateBlob: RevisionStateBlobCodec.encode(
            revisions: [],
            activeRevisionID: nil
        ),
        canonicalSignatureBlob: SignatureBlobCodec.encode(bundle.signatureEntries),
        projectionSchemaVersion: schemaVersion,
        title: title,
        searchBody: bundle.projection.searchBody,
        effectiveTypeIdentifiersBlob: EffectiveTypeIdentifiersBlobCodec.encode(
            bundle.projection.effectiveTypeIdentifiers
        ),
        firstCopiedAt: observedAt,
        lastCopiedAt: lastCopiedAt,
        copyCount: copyCount,
        firstSource: "com.example.projection-corruption",
        lastSource: lastSource,
        pinOrdinal: nil
    )
    row.searchBodyUTF8 = searchBodyUTF8
    if corruption == .malformedTitleUTF8 {
        row.titleUTF8 = Data([0xEF, 0xBB, 0xBF, 0xFF])
        // A plausible legacy String must not become a fallback for damaged
        // current title bytes; current reads fail closed instead.
        row.title = bundle.projection.title
    }
    if corruption == .malformedSearchBodyUTF8 {
        row.searchBodyUTF8 = Data("projection corruption control".utf8) + Data([0xFF])
        // Search must reject malformed current bytes rather than accepting a
        // valid prefix or falling back to this plausible legacy String.
        row.searchBody = bundle.projection.searchBody
    }
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let context = ModelContext(container)
    // This is a raw current store fixture, not a fresh-store bootstrap. Keep its
    // authoritative singleton shape valid so only `corruption` selects the
    // startup/read failure under test (05 §13; DATA-1).
    context.insert(LastChangePositionRow(
        key: HistoryAuthority.positionSingletonKey,
        rawValue: 1,
        maximumUnpinnedItems: 200
    ))
    context.insert(row)
    // V2-02 §3.3b (roadmap R.3): every test this fixture feeds except the
    // schemaVersion one expects startup to SUCCEED, so the crafted store
    // must satisfy the step-7 `RetainedBytesRow` 1:1 law — the row's
    // projection is exactly what the capture-insert stamping would write
    // (signature byte-count sum; empty revision list ⇒ revisionCount 0 /
    // revisionBytes 0; `bytesSchemaVersion == 1`), keeping the corruption
    // under test confined to the one damaged scalar/projection field.
    var canonicalBytes = 0
    for entry in bundle.signatureEntries {
        canonicalBytes += entry.byteCount
    }
    context.insert(RetainedBytesRow(
        itemID: bundle.domain.candidateID.rawValue,
        canonicalBytes: canonicalBytes,
        revisionCount: 0,
        revisionBytes: 0,
        bytesSchemaVersion: 1
    ))
    try context.save()
    return bundle.domain.candidateID
}

/// Shared only with Card 11A's public-facade admission proof. Keeping the
/// malformed row construction here ensures its corpus poison is the same real
/// durable scalar already used by the owning Part VI §7.4 read-boundary test.
static func seedOverBoundSearchBodyRow(
    at storeURL: URL
) async throws -> HistoryItemID {
    try await seedRow(at: storeURL, corruption: .searchBody)
}

/// Startup consumes the projection schema tag while rebuilding scalar
/// metadata, so an unknown tag prevents the facade from being published.
@Test func startupRejectsUnknownProjectionSchemaVersion() async throws {
    let storeURL = WSSupport.tempStoreURL("projection-corrupt-schema")
    defer { WSSupport.removeStore(storeURL) }
    _ = try await Self.seedRow(at: storeURL, corruption: .schemaVersion)

    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await WSSupport.makeAuthority(storeURL: storeURL)
    }
}

/// Title is consumed by recent, search, and full-lineage reads; each path
/// independently re-validates the UTF-8 bound instead of trusting write-time
/// projection or silently truncating corrupted durable state.
@Test func overBoundStoredTitleFailsEveryTitleConsumingRead() async throws {
    let storeURL = WSSupport.tempStoreURL("projection-corrupt-title")
    defer { WSSupport.removeStore(storeURL) }
    let itemID = try await Self.seedRow(at: storeURL, corruption: .title)
    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)

    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await authority.recentPage(limit: 10, after: nil)
    }
    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await authority.searchCorpusSnapshot(
            for: HistoryBrowseRequest(
                kind: .search(text: "projection", mode: .exact),
                limit: 10
            )
        )
    }
    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await authority.details(for: itemID)
    }
}

@Test func malformedStoredTitleFailsClosedThroughPublicReads() async throws {
    let storeURL = WSSupport.tempStoreURL("projection-invalid-title-utf8")
    defer { WSSupport.removeStore(storeURL) }
    let itemID = try await Self.seedRow(at: storeURL, corruption: .malformedTitleUTF8)
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
    }
    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "projection", mode: .exact), limit: 10
        ))
    }
    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await history.details(for: itemID)
    }
}

/// Recent browse deliberately does not fetch searchBodyUTF8, while search and
/// lineage hydration do. This pins both fail-closed validation and the scalar
/// isolation boundary: an unrelated recent read remains available.
@Test func overBoundStoredSearchBodyFailsOnlyBodyConsumingReads() async throws {
    let storeURL = WSSupport.tempStoreURL("projection-corrupt-search-body")
    defer { WSSupport.removeStore(storeURL) }
    let itemID = try await Self.seedRow(at: storeURL, corruption: .searchBody)
    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)

    let recent = try await authority.recentPage(limit: 10, after: nil)
    #expect(recent.rows.map(\.item.id) == [itemID])

    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await authority.searchCorpusSnapshot(
            for: HistoryBrowseRequest(
                kind: .search(text: "projection", mode: .exact),
                limit: 10
            )
        )
    }
    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await authority.details(for: itemID)
    }
}

@Test func malformedStoredSearchBodyRejectsPublicSearchButLeavesRecentAvailable() async throws {
    let storeURL = WSSupport.tempStoreURL("projection-invalid-body-utf8")
    defer { WSSupport.removeStore(storeURL) }
    let itemID = try await Self.seedRow(at: storeURL, corruption: .malformedSearchBodyUTF8)
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
    #expect(recent.rows.map(\.item.id) == [itemID])
    #expect(recent.rows.map(\.title) == ["projection corruption control"])
    for mode in [SearchMode.exact, .fuzzy, .regexp] {
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            _ = try await history.browse(HistoryBrowseRequest(
                kind: .search(text: "projection", mode: mode), limit: 10
            ))
        }
    }
    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await history.details(for: itemID)
    }
    let afterFailure = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
    #expect(afterFailure == recent)
}

/// Occurrence scalars are consumed without full lineage hydration by recent,
/// search, and retention. Each path must apply the same fail-closed checks as
/// `decodeOccurrence` before sorting, cursor minting, or planning.
@Test(
    arguments: [
        Corruption.lastCopiedAt,
        .copyCount,
        .lastSource,
    ]
)
private func occurrenceScalarCorruptionFailsEveryConsumingPath(
    corruption: Corruption
) async throws {
    let storeURL = WSSupport.tempStoreURL("projection-corrupt-occurrence-\(corruption)")
    defer { WSSupport.removeStore(storeURL) }
    let itemID = try await Self.seedRow(at: storeURL, corruption: corruption)
    let authority = try await WSSupport.makeAuthority(storeURL: storeURL)

    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await authority.recentPage(limit: 10, after: nil)
    }
    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await authority.searchCorpusSnapshot(
            for: HistoryBrowseRequest(
                kind: .search(text: "projection", mode: .exact),
                limit: 10
            )
        )
    }
    await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
        _ = try await authority.details(for: itemID)
    }
    if corruption == .lastCopiedAt {
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            _ = try await authority.commitRetentionPolicy(199)
        }
    }
}
}
