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
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    let observedAt = Date(timeIntervalSinceReferenceDate: 700_050_000)
    let receipt = try await history.perform(.capture(WSSupport.textCapture(
        "projection corruption control",
        observedAt: observedAt,
        source: "com.example.projection-corruption"
    )))
    guard case let .committed(commit) = receipt,
          case let .inserted(reference) = commit.outcome else {
        throw FixtureFailure.expectedInsert
    }

    // Real capture creates every current singleton, journal, blob and byte
    // projection. Mutate only the chosen scalar in an independent context;
    // no startup compatibility or repair makes this fixture valid.
    let context = ModelContext(try WSSupport.makeContainer(storeURL: storeURL))
    context.autosaveEnabled = false
    let rows = try context.fetch(FetchDescriptor<HistoryItemRow>())
    let row = try #require(rows.count == 1 ? rows.first : nil)
    #expect(row.id == reference.id.rawValue)
    switch corruption {
    case .title:
        row.titleUTF8 = Data(
            repeating: 0x74,
            count: HistoryLimits.standard.maximumStoredTitleUTF8Bytes + 1
        )
    case .malformedTitleUTF8:
        row.titleUTF8 = Data([0xEF, 0xBB, 0xBF, 0xFF])
    case .searchBody:
        row.searchBodyUTF8 = Data(
            repeating: 0x62,
            count: HistoryLimits.standard.maximumStoredSearchBodyUTF8Bytes + 1
        )
    case .malformedSearchBodyUTF8:
        row.searchBodyUTF8 = Data("projection corruption control".utf8) + Data([0xFF])
    case .lastCopiedAt:
        // SQLite binds NaN as NULL; Infinity reaches the durable validator.
        row.lastCopiedAt = Date(timeIntervalSinceReferenceDate: .infinity)
    case .copyCount:
        row.copyCount = 0
    case .lastSource:
        row.lastSource = String(
            repeating: "s",
            count: HistoryLimits.standard.maximumSourceApplicationObservationUTF8Bytes + 1
        )
    }
    try context.save()
    return reference.id
}

private enum FixtureFailure: Error { case expectedInsert }

/// Shared only with Card 11A's public-facade admission proof. Keeping the
/// malformed row construction here ensures its corpus poison is the same real
/// durable scalar already used by the owning Part VI §7.4 read-boundary test.
static func seedOverBoundSearchBodyRow(
    at storeURL: URL
) async throws -> HistoryItemID {
    try await seedRow(at: storeURL, corruption: .searchBody)
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
