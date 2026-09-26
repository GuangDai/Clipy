/// Sorting is part of a page's query identity. Explicit copy-metadata ordering
/// binds its complete boundary facts; automatic keeps the v3 default payload.
/// docs/04-coherence.md §6.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct CursorSortTests {
    private let processMarker = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    private let itemID = HistoryItemID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!)
    private let date = Date(timeIntervalSinceReferenceDate: 123_456.5)

    @Test func requestsKeepAutomaticAsDefaultAndDistinguishExplicitOrdering() {
        let browse = HistoryBrowseRequest(kind: .recent, limit: 3)
        let observation = HistoryObservationRequest(kind: .recent, limit: 3)
        #expect(browse.sortOrder == .automatic)
        #expect(observation.sortOrder == .automatic)
        #expect(browse != HistoryBrowseRequest(kind: .recent, limit: 3, sortOrder: .newestFirst))
        #expect(observation != HistoryObservationRequest(kind: .recent, limit: 3, sortOrder: .newestFirst))
    }

    @Test func everyQueryKindBindsItsOrderingThroughCursorRoundTrip() throws {
        let kinds: [HistoryBrowseKind] = [
            .recent, .search(text: "needle", mode: .exact),
            .search(text: "nedle", mode: .fuzzy), .search(text: "n.*e", mode: .regexp),
            .search(text: "needle", mode: .expression)
        ]
        let filter = HistoryFilter(type: .text, pinnedOnly: true, sourceApplication: "editor")
        for kind in kinds {
            for sortOrder in HistorySortOrder.allCases {
                let request = HistoryBrowseRequest(kind: kind, limit: 3, filter: filter, sortOrder: sortOrder)
                let shape = StoredQueryShape(request: request)
                for direction in [HistoryPageDirection.forward, .backward] {
                    let expected = ResolvedPageCursor(
                        queryShape: shape, position: ChangePosition(rawValue: 42),
                        anchor: anchor(for: sortOrder), direction: direction
                    )
                    let encoded = try PageCursorCodec.encode(expected, processMarker: processMarker)
                    let decoded = try PageCursorCodec.decode(encoded, processMarker: processMarker)
                    #expect(decoded == expected)
                    #expect(decoded.queryShape.matches(request))
                    for otherOrder in HistorySortOrder.allCases where otherOrder != sortOrder {
                        #expect(!decoded.queryShape.matches(HistoryBrowseRequest(
                            kind: kind, limit: 3, filter: filter, sortOrder: otherOrder
                        )))
                    }
                }
            }
        }
    }

    @Test func automaticOmitsNewFieldsAndAcceptsExplicitAutomaticTag() throws {
        let cursor = try encode(sortOrder: .automatic)
        let root = try #require(JSONSerialization.jsonObject(with: cursor.payload) as? [String: Any])
        let query = try #require(root["queryShape"] as? [String: Any])
        let anchor = try #require(root["anchor"] as? [String: Any])
        #expect(query["sortOrder"] == nil)
        #expect(anchor["copyCount"] == nil)
        let explicit = try replacingObject("queryShape", in: cursor) { $0["sortOrder"] = "automatic" }
        #expect(try PageCursorCodec.decode(cursor, processMarker: processMarker)
                == PageCursorCodec.decode(explicit, processMarker: processMarker))
    }

    @Test func unknownSortOrderIsRejected() throws {
        let cursor = try replacingObject("queryShape", in: encode(sortOrder: .newestFirst)) {
            $0["sortOrder"] = "futureOrder"
        }
        #expect(throws: PageCursorRejection.malformedCursor) {
            try PageCursorCodec.decode(cursor, processMarker: processMarker)
        }
    }

    @Test func metadataPreservesTheFullUnsignedCopyCount() throws {
        let expected = ResolvedPageCursor(
            queryShape: .recent(limit: 3, sortOrder: .mostCopied),
            position: ChangePosition(rawValue: 42),
            anchor: .metadata(lastCopiedAt: date, copyCount: UInt64.max, id: itemID)
        )
        let cursor = try PageCursorCodec.encode(expected, processMarker: processMarker)
        #expect(try PageCursorCodec.decode(cursor, processMarker: processMarker) == expected)
    }

    @Test(arguments: ["missingCount", "zeroCount", "negativeCount", "fractionalCount",
                      "missingDate", "missingID", "pinnedOrdinal", "score"])
    func metadataRejectsMissingInvalidAndContradictoryFacts(_ mutation: String) throws {
        let cursor = try replacingObject("anchor", in: encode(sortOrder: .mostCopied)) { anchor in
            switch mutation {
            case "missingCount": anchor.removeValue(forKey: "copyCount")
            case "zeroCount": anchor["copyCount"] = 0
            case "negativeCount": anchor["copyCount"] = -1
            case "fractionalCount": anchor["copyCount"] = 1.5
            case "missingDate": anchor.removeValue(forKey: "lastCopiedAt")
            case "missingID": anchor.removeValue(forKey: "id")
            case "pinnedOrdinal": anchor["pinnedOrdinal"] = 0
            case "score": anchor["score"] = 0.5
            default: Issue.record("Unknown cursor mutation")
            }
        }
        #expect(throws: PageCursorRejection.malformedCursor) {
            try PageCursorCodec.decode(cursor, processMarker: processMarker)
        }
    }

    @Test func automaticAnchorsRejectCopyCountFromAnotherOrderingLane() throws {
        let anchors: [StoredOrderingAnchor] = [
            .defaultOrder(pinnedOrdinal: nil, lastCopiedAt: date, id: itemID),
            .fuzzyUnpinned(score: 0.25, lastCopiedAt: date, id: itemID)
        ]
        for anchor in anchors {
            let original = try PageCursorCodec.encode(
                ResolvedPageCursor(queryShape: .search(text: "needle", mode: .fuzzy, limit: 3),
                                   position: ChangePosition(rawValue: 42), anchor: anchor),
                processMarker: processMarker
            )
            let cursor = try replacingObject("anchor", in: original) { $0["copyCount"] = 1 }
            #expect(throws: PageCursorRejection.malformedCursor) {
                try PageCursorCodec.decode(cursor, processMarker: processMarker)
            }
        }
    }

    @Test func metadataCannotEncodeANonFiniteDate() {
        let cursor = ResolvedPageCursor(
            queryShape: .recent(limit: 3, sortOrder: .oldestFirst),
            position: ChangePosition(rawValue: 42),
            anchor: .metadata(lastCopiedAt: Date(timeIntervalSinceReferenceDate: .infinity),
                              copyCount: 1, id: itemID)
        )
        #expect(throws: PageCursorRejection.encodingFailed) {
            try PageCursorCodec.encode(cursor, processMarker: processMarker)
        }
    }

    private func anchor(for sortOrder: HistorySortOrder) -> StoredOrderingAnchor {
        if sortOrder == .automatic {
            return .defaultOrder(pinnedOrdinal: nil, lastCopiedAt: date, id: itemID)
        }
        return .metadata(lastCopiedAt: date, copyCount: 5, id: itemID)
    }

    private func encode(sortOrder: HistorySortOrder) throws -> HistoryPageCursor {
        try PageCursorCodec.encode(
            ResolvedPageCursor(queryShape: .recent(limit: 3, sortOrder: sortOrder),
                               position: ChangePosition(rawValue: 42), anchor: anchor(for: sortOrder)),
            processMarker: processMarker
        )
    }

    private func replacingObject(
        _ key: String, in cursor: HistoryPageCursor,
        mutation: (inout [String: Any]) -> Void
    ) throws -> HistoryPageCursor {
        var root = try #require(JSONSerialization.jsonObject(with: cursor.payload) as? [String: Any])
        var object = try #require(root[key] as? [String: Any])
        mutation(&object)
        root[key] = object
        return HistoryPageCursor(payload: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]))
    }
}
