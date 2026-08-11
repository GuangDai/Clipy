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
    case searchBody
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
    let searchBody = corruption == .searchBody
        ? String(
            repeating: "b",
            count: HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes + 1
        )
        : bundle.projection.searchBody
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
        searchBody: searchBody,
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
    let container = try WSSupport.makeContainer(storeURL: storeURL)
    let context = ModelContext(container)
    context.insert(row)
    try context.save()
    return bundle.domain.candidateID
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

/// Recent browse deliberately does not fetch searchBody, while search and
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
