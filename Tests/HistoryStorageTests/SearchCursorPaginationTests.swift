/// Search continuation coverage for docs/04-coherence.md §6 and
/// docs/05-authority-kernel.md §14.2. These facade-driven tests complement
/// WS18's `.recent` cursor proofs by exercising every frozen search mode,
/// both search ordering-anchor families, and position expiry after a commit.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct SearchCursorPaginationTests {

private static let modes: [SearchMode] = [.exact, .fuzzy, .regexp]

private static func modeName(_ mode: SearchMode) -> String {
    switch mode {
    case .exact: return "exact"
    case .fuzzy: return "fuzzy"
    case .regexp: return "regexp"
    }
}

/// Inserts distinct rows that every mode matches at title offset zero. The
/// fuzzy hits consequently have equal scores and are ordered by recency,
/// while exact/regexp retain the same default unpinned order.
private static func captureMatchingRows(
    _ history: SwiftDataHistory,
    count: Int,
    base: Double
) async throws -> [HistoryItemID] {
    var ids: [HistoryItemID] = []
    for index in 0..<count {
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                "alpha item \(index)",
                observedAt: Date(
                    timeIntervalSinceReferenceDate: base + Double(index)
                ),
                source: "com.example.search-cursor"
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome else {
            Issue.record(
                "Search cursor arrange: expected inserted row \(index), got \(receipt)"
            )
            throw HistoryFailure.persistence(.invariantViolation)
        }
        ids.append(reference.id)
    }
    return ids
}

/// Replaces only the anchor ID while preserving a structurally valid cursor,
/// its process marker, query shape, position, and all remaining anchor fields.
private static func replacingAnchorID(
    in cursor: HistoryPageCursor,
    with id: UUID
) throws -> HistoryPageCursor {
    var root = try #require(
        JSONSerialization.jsonObject(with: cursor.payload) as? [String: Any]
    )
    var anchor = try #require(root["anchor"] as? [String: Any])
    anchor["id"] = id.uuidString
    root["anchor"] = anchor
    return HistoryPageCursor(payload: try JSONSerialization.data(
        withJSONObject: root,
        options: [.sortedKeys]
    ))
}

/// 04 §6/05 §14.2: exact, fuzzy, and regexp search cursors each resume over
/// three pages without a gap or repeat. This exercises `.defaultOrder` for
/// exact/regexp and `.fuzzyUnpinned` for fuzzy.
@Test func everySearchModeResumesAcrossThreePagesWithoutGapOrRepeat() async throws {
    let storeURL = WSSupport.tempStoreURL("search-cursor-pagination")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    let ids = try await Self.captureMatchingRows(
        history,
        count: 5,
        base: 700_080_000
    )
    let expected = Array(ids.reversed())

    for mode in Self.modes {
        let kind = HistoryBrowseKind.search(text: "alpha", mode: mode)

        let page1 = try await history.browse(HistoryBrowseRequest(
            kind: kind,
            limit: 2
        ))
        let cursor1 = try #require(
            page1.next,
            "\(Self.modeName(mode)) search page 1 must mint a cursor"
        )
        let page2 = try await history.browse(HistoryBrowseRequest(
            kind: kind,
            limit: 2,
            after: cursor1
        ))
        let cursor2 = try #require(
            page2.next,
            "\(Self.modeName(mode)) search page 2 must mint a cursor"
        )
        let page3 = try await history.browse(HistoryBrowseRequest(
            kind: kind,
            limit: 2,
            after: cursor2
        ))

        let actual = page1.rows.map(\.item.id)
            + page2.rows.map(\.item.id)
            + page3.rows.map(\.item.id)
        #expect(
            [page1.rows.count, page2.rows.count, page3.rows.count] == [2, 2, 1],
            "\(Self.modeName(mode)) search must divide five rows into 2/2/1"
        )
        #expect(
            actual == expected,
            "\(Self.modeName(mode)) continuation must preserve the complete order"
        )
        #expect(
            Set(actual).count == expected.count,
            "\(Self.modeName(mode)) continuation must not repeat a row"
        )
        #expect(
            page2.position == page1.position && page3.position == page1.position,
            "\(Self.modeName(mode)) continuation pages bind one snapshot position"
        )
        #expect(
            page3.next == nil,
            "\(Self.modeName(mode)) final search page must not mint a cursor"
        )
    }
}

/// 04 §6: a validly encoded search cursor whose anchor names no evaluated
/// row expires explicitly at the unchanged corpus position. All three modes
/// are covered so both search anchor families execute this fail-closed path.
@Test func missingSearchAnchorExpiresForEveryModeAtCurrentPosition() async throws {
    let storeURL = WSSupport.tempStoreURL("search-cursor-missing-anchor")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    _ = try await Self.captureMatchingRows(
        history,
        count: 5,
        base: 700_081_000
    )
    let foreignID = UUID(
        uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"
    )!

    for mode in Self.modes {
        let kind = HistoryBrowseKind.search(text: "alpha", mode: mode)
        let firstPage = try await history.browse(HistoryBrowseRequest(
            kind: kind,
            limit: 2
        ))
        let validCursor = try #require(firstPage.next)
        let missingAnchorCursor = try Self.replacingAnchorID(
            in: validCursor,
            with: foreignID
        )

        await #expect(
            throws: HistoryFailure.snapshotExpired(current: firstPage.position)
        ) {
            try await history.browse(HistoryBrowseRequest(
                kind: kind,
                limit: 2,
                after: missingAnchorCursor
            ))
        }
    }
}

/// 04 §6 step 3: any intervening History Commit expires every search cursor
/// bound to the prior position, independently of mode or anchor family.
@Test func interveningCommitExpiresEverySearchModeCursor() async throws {
    let storeURL = WSSupport.tempStoreURL("search-cursor-commit-expiry")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    _ = try await Self.captureMatchingRows(
        history,
        count: 5,
        base: 700_082_000
    )

    var cursors: [(mode: SearchMode, cursor: HistoryPageCursor)] = []
    for mode in Self.modes {
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "alpha", mode: mode),
            limit: 2
        ))
        cursors.append((mode, try #require(page.next)))
    }

    let receipt = try await history.perform(.capture(WSSupport.textCapture(
        "alpha item after cursor",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_083_000),
        source: "com.example.search-cursor.commit"
    )))
    guard case let .committed(commit) = receipt else {
        Issue.record("Search cursor arrange: intervening capture did not commit")
        return
    }

    for entry in cursors {
        await #expect(
            throws: HistoryFailure.snapshotExpired(current: commit.position)
        ) {
            try await history.browse(HistoryBrowseRequest(
                kind: .search(text: "alpha", mode: entry.mode),
                limit: 2,
                after: entry.cursor
            ))
        }
    }
}
}
