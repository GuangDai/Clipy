/// Direct cursor-codec proofs for the opaque, process-local pagination token
/// (docs/04-coherence.md §6; docs/05-authority-kernel.md §16).
///
/// These tests use the package-only codec seam deliberately: callers cannot
/// mint or inspect `HistoryPageCursor`, while HistoryStorage must prove every
/// wire rejection and the encode-side invariant failure independently of a
/// particular browse fixture.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

private let cursorProcessMarker = UUID(
    uuidString: "00000000-0000-0000-0000-0000000000C1"
)!

private let foreignCursorProcessMarker = UUID(
    uuidString: "00000000-0000-0000-0000-0000000000C2"
)!

private let cursorItemID = HistoryItemID(rawValue: UUID(
    uuidString: "00000000-0000-0000-0000-0000000000C3"
)!)

private let cursorDate = Date(timeIntervalSinceReferenceDate: 123_456.5)

private struct CursorWireStrategyFixture: Codable, Equatable {
    let data: Data
    let date: Date
}

private func encodedCursor(
    queryShape: StoredQueryShape = .recent(limit: 3),
    anchor: StoredOrderingAnchor = .defaultOrder(
        pinnedOrdinal: nil,
        lastCopiedAt: cursorDate,
        id: cursorItemID
    ),
    processMarker: UUID = cursorProcessMarker
) throws -> HistoryPageCursor {
    try PageCursorCodec.encode(
        ResolvedPageCursor(
            queryShape: queryShape,
            position: ChangePosition(rawValue: 42),
            anchor: anchor
        ),
        processMarker: processMarker
    )
}

private func cursorByMutatingJSON(
    _ cursor: HistoryPageCursor,
    mutation: (inout [String: Any]) throws -> Void
) throws -> HistoryPageCursor {
    var root = try #require(
        JSONSerialization.jsonObject(with: cursor.payload) as? [String: Any]
    )
    try mutation(&root)
    return HistoryPageCursor(payload: try JSONSerialization.data(
        withJSONObject: root,
        options: [.sortedKeys]
    ))
}

private func mutateCursorObject(
    named key: String,
    in root: inout [String: Any],
    mutation: (inout [String: Any]) -> Void
) throws {
    var object = try #require(root[key] as? [String: Any])
    mutation(&object)
    root[key] = object
}

/// Every query/anchor family used by recent, exact, fuzzy, and regexp browse
/// survives the codec without losing its complete normalized shape or sort
/// key (04 §6).
@Test func cursorRoundTripPreservesQueryShapesAndOrderingAnchors() throws {
    let values: [ResolvedPageCursor] = [
        ResolvedPageCursor(
            queryShape: .recent(limit: 3),
            position: ChangePosition(rawValue: 1),
            anchor: .defaultOrder(
                pinnedOrdinal: 0,
                lastCopiedAt: cursorDate,
                id: cursorItemID
            )
        ),
        ResolvedPageCursor(
            queryShape: .recent(limit: 4),
            position: ChangePosition(rawValue: 2),
            anchor: .defaultOrder(
                pinnedOrdinal: nil,
                lastCopiedAt: cursorDate,
                id: cursorItemID
            )
        ),
        ResolvedPageCursor(
            queryShape: .search(text: "needle", mode: .exact, limit: 5),
            position: ChangePosition(rawValue: 3),
            anchor: .defaultOrder(
                pinnedOrdinal: nil,
                lastCopiedAt: cursorDate,
                id: cursorItemID
            )
        ),
        ResolvedPageCursor(
            queryShape: .search(text: "nedle", mode: .fuzzy, limit: 6),
            position: ChangePosition(rawValue: 4),
            anchor: .defaultOrder(
                pinnedOrdinal: 1,
                lastCopiedAt: cursorDate,
                id: cursorItemID
            )
        ),
        ResolvedPageCursor(
            queryShape: .search(text: "nedle", mode: .fuzzy, limit: 6),
            position: ChangePosition(rawValue: 5),
            anchor: .fuzzyUnpinned(
                score: 0.25,
                lastCopiedAt: cursorDate,
                id: cursorItemID
            )
        ),
        ResolvedPageCursor(
            queryShape: .search(text: "n.*e", mode: .regexp, limit: 7),
            position: ChangePosition(rawValue: 6),
            anchor: .defaultOrder(
                pinnedOrdinal: 2,
                lastCopiedAt: cursorDate,
                id: cursorItemID
            )
        ),
    ]

    for value in values {
        let encoded = try PageCursorCodec.encode(
            value,
            processMarker: cursorProcessMarker
        )
        let decoded = try PageCursorCodec.decode(
            encoded,
            processMarker: cursorProcessMarker
        )
        #expect(decoded == value)
    }
}

@Test func cursorDecodeRejectsGarbagePayload() {
    do {
        _ = try PageCursorCodec.decode(
            HistoryPageCursor(payload: Data([0xFF, 0x00, 0x7F])),
            processMarker: cursorProcessMarker
        )
        Issue.record("garbage cursor payload decoded successfully")
    } catch PageCursorRejection.malformedCursor {
        // Expected.
    } catch {
        Issue.record("garbage cursor produced the wrong rejection: \(error)")
    }
}

@Test func cursorWireStrategiesProduceStableBytes() throws {
    let cursor = try encodedCursor()
    let expected = Data(
        #"{"anchor":{"id":"00000000-0000-0000-0000-0000000000C3","kind":"defaultOrder","lastCopiedAt":123456.5},"formatVersion":1,"processMarker":"00000000-0000-0000-0000-0000000000C1","queryShape":{"kind":"recent","limit":3},"rawValue":42}"#.utf8
    )
    #expect(cursor.payload == expected)
    #expect(try encodedCursor().payload == expected)

    let strategyFixture = CursorWireStrategyFixture(
        data: Data([0x00, 0xFF]),
        date: cursorDate
    )
    let fixtureBytes = try CodecWireFormat.makeEncoder().encode(strategyFixture)
    #expect(fixtureBytes == Data(#"{"data":"AP8=","date":123456.5}"#.utf8))
    #expect(
        try CodecWireFormat.makeDecoder().decode(
            CursorWireStrategyFixture.self,
            from: fixtureBytes
        ) == strategyFixture
    )
}

@Test func cursorDecodeRejectsPayloadOverPreparseEnvelope() {
    let cursor = HistoryPageCursor(
        payload: Data(count: PageCursorCodec.maximumPayloadBytes + 1)
    )
    #expect(throws: PageCursorRejection.malformedCursor) {
        try PageCursorCodec.decode(cursor, processMarker: cursorProcessMarker)
    }
}

@Test func cursorDecodeRejectsTruncatedPayload() throws {
    let valid = try encodedCursor()
    let truncated = HistoryPageCursor(payload: Data(valid.payload.dropLast()))

    do {
        _ = try PageCursorCodec.decode(
            truncated,
            processMarker: cursorProcessMarker
        )
        Issue.record("truncated cursor payload decoded successfully")
    } catch PageCursorRejection.malformedCursor {
        // Expected.
    } catch {
        Issue.record("truncated cursor produced the wrong rejection: \(error)")
    }
}

@Test func cursorDecodeRejectsUnknownVersion() throws {
    let mutated = try cursorByMutatingJSON(encodedCursor()) { root in
        root["formatVersion"] = 2
    }

    do {
        _ = try PageCursorCodec.decode(
            mutated,
            processMarker: cursorProcessMarker
        )
        Issue.record("unknown cursor version decoded successfully")
    } catch PageCursorRejection.unknownCursorVersion(let found) {
        #expect(found == 2)
    } catch {
        Issue.record("unknown version produced the wrong rejection: \(error)")
    }
}

@Test func cursorDecodeRejectsUnknownQueryKind() throws {
    let mutated = try cursorByMutatingJSON(encodedCursor()) { root in
        try mutateCursorObject(named: "queryShape", in: &root) { queryShape in
            queryShape["kind"] = "future"
        }
    }

    do {
        _ = try PageCursorCodec.decode(
            mutated,
            processMarker: cursorProcessMarker
        )
        Issue.record("unknown cursor query kind decoded successfully")
    } catch PageCursorRejection.malformedCursor {
        // Expected.
    } catch {
        Issue.record("unknown query kind produced the wrong rejection: \(error)")
    }
}

@Test func cursorDecodeRejectsUnknownAnchorKind() throws {
    let mutated = try cursorByMutatingJSON(encodedCursor()) { root in
        try mutateCursorObject(named: "anchor", in: &root) { anchor in
            anchor["kind"] = "future"
        }
    }

    do {
        _ = try PageCursorCodec.decode(
            mutated,
            processMarker: cursorProcessMarker
        )
        Issue.record("unknown cursor anchor kind decoded successfully")
    } catch PageCursorRejection.malformedCursor {
        // Expected.
    } catch {
        Issue.record("unknown anchor kind produced the wrong rejection: \(error)")
    }
}

@Test func cursorDecodeRejectsUnknownSearchMode() throws {
    let valid = try encodedCursor(
        queryShape: .search(text: "needle", mode: .exact, limit: 3)
    )
    let mutated = try cursorByMutatingJSON(valid) { root in
        try mutateCursorObject(named: "queryShape", in: &root) { queryShape in
            queryShape["mode"] = "future"
        }
    }

    do {
        _ = try PageCursorCodec.decode(
            mutated,
            processMarker: cursorProcessMarker
        )
        Issue.record("unknown cursor search mode decoded successfully")
    } catch PageCursorRejection.malformedCursor {
        // Expected.
    } catch {
        Issue.record("unknown search mode produced the wrong rejection: \(error)")
    }
}

@Test func cursorDecodeRejectsForeignProcessMarker() throws {
    let cursor = try encodedCursor(processMarker: cursorProcessMarker)

    do {
        _ = try PageCursorCodec.decode(
            cursor,
            processMarker: foreignCursorProcessMarker
        )
        Issue.record("foreign-process cursor decoded successfully")
    } catch PageCursorRejection.processMarkerMismatch {
        // Expected.
    } catch {
        Issue.record("foreign marker produced the wrong rejection: \(error)")
    }
}

@Test func cursorDecodeRejectsMissingAnchorField() throws {
    let mutated = try cursorByMutatingJSON(encodedCursor()) { root in
        try mutateCursorObject(named: "anchor", in: &root) { anchor in
            anchor.removeValue(forKey: "id")
        }
    }

    do {
        _ = try PageCursorCodec.decode(
            mutated,
            processMarker: cursorProcessMarker
        )
        Issue.record("cursor missing its anchor ID decoded successfully")
    } catch PageCursorRejection.malformedCursor {
        // Expected.
    } catch {
        Issue.record("missing anchor field produced the wrong rejection: \(error)")
    }
}

@Test func cursorDecodeRejectsContradictoryOrOutOfBoundKnownFields() throws {
    let negativeOrdinal = try cursorByMutatingJSON(encodedCursor()) { root in
        try mutateCursorObject(named: "anchor", in: &root) { anchor in
            anchor["pinnedOrdinal"] = -1
        }
    }
    #expect(throws: PageCursorRejection.malformedCursor) {
        try PageCursorCodec.decode(
            negativeOrdinal,
            processMarker: cursorProcessMarker
        )
    }

    let defaultWithScore = try cursorByMutatingJSON(encodedCursor()) { root in
        try mutateCursorObject(named: "anchor", in: &root) { anchor in
            anchor["score"] = 0.5
        }
    }
    #expect(throws: PageCursorRejection.malformedCursor) {
        try PageCursorCodec.decode(
            defaultWithScore,
            processMarker: cursorProcessMarker
        )
    }

    let invalidLimit = try cursorByMutatingJSON(encodedCursor()) { root in
        try mutateCursorObject(named: "queryShape", in: &root) { query in
            query["limit"] = 0
        }
    }
    #expect(throws: PageCursorRejection.malformedCursor) {
        try PageCursorCodec.decode(invalidLimit, processMarker: cursorProcessMarker)
    }

    let recentWithSearchFields = try cursorByMutatingJSON(encodedCursor()) { root in
        try mutateCursorObject(named: "queryShape", in: &root) { query in
            query["text"] = "unexpected"
            query["mode"] = "exact"
        }
    }
    #expect(throws: PageCursorRejection.malformedCursor) {
        try PageCursorCodec.decode(
            recentWithSearchFields,
            processMarker: cursorProcessMarker
        )
    }
}

@Test func cursorDecodeIgnoresSemanticallyInertUnknownMetadata() throws {
    let expected = try encodedCursor()
    let extended = try cursorByMutatingJSON(expected) { root in
        root["futureMetadata"] = "ignored-by-v1"
        try mutateCursorObject(named: "anchor", in: &root) { anchor in
            anchor["futureAnchorMetadata"] = true
        }
    }

    #expect(
        try PageCursorCodec.decode(extended, processMarker: cursorProcessMarker)
            == PageCursorCodec.decode(expected, processMarker: cursorProcessMarker)
    )
}

/// An impossible primitive encoding value must fail at the minting boundary;
/// it must never be converted into an empty payload that later masquerades as
/// an expired snapshot.
@Test func cursorEncodeSurfacesEncodingFailure() {
    let value = ResolvedPageCursor(
        queryShape: .search(text: "needle", mode: .fuzzy, limit: 3),
        position: ChangePosition(rawValue: 42),
        anchor: .fuzzyUnpinned(
            score: .nan,
            lastCopiedAt: cursorDate,
            id: cursorItemID
        )
    )

    do {
        _ = try PageCursorCodec.encode(
            value,
            processMarker: cursorProcessMarker
        )
        Issue.record("non-finite cursor score encoded successfully")
    } catch PageCursorRejection.encodingFailed {
        // Expected.
    } catch {
        Issue.record("cursor encode produced the wrong rejection: \(error)")
    }
}
