import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// One history occurrence owns ordered system pasteboard items. The same
/// type on two items is two independently addressable immutable payloads.
struct SQLiteMultiItemHistoryTests {
    private let type = "public.utf8-plain-text"

    @Test func identicalItemsCoalesceButSwappingItemsAndChangingItemCountDoNot() async throws {
        let history = try await WSSupport.makeHistory()
        let original = try inserted(await history.perform(.capture(capture(["alpha", "beta"]))))
        let repeatReceipt = try await history.perform(.capture(capture(["alpha", "beta"])))
        guard case .committed(let commit) = repeatReceipt, case .coalesced(let repeated) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(repeated == original)
        let swapped = try inserted(await history.perform(.capture(capture(["beta", "alpha"]))))
        let single = try inserted(await history.perform(.capture(capture(["alpha"]))))
        #expect(swapped.id != original.id)
        #expect(single.id != original.id)
        let page = try await history.browse(.init(kind: .recent, limit: 10))
        #expect(page.rows.count == 3)
        #expect(page.rows.first(where: { $0.item.id == original.id })?.copyCount == 2)
        let payload = try await history.pastePayload(for: original.id)
        #expect(payload.representations.map(\.pasteboardItemIndex) == [0, 1])
        #expect(payload.representations.map(\.bytes) == [Data("alpha".utf8), Data("beta".utf8)])
    }

    @Test func collidingPostingsCompareEachItemsBytesBeforeCoalescing() async throws {
        let history = try await WSSupport.makeHistory()
        let preparation = IngestPreparationActor(fingerprint: ForcedCollisionFingerprint.digest(of:))
        var items: [HistoryItemReference] = []
        for values in [["aa", "bb"], ["bb", "aa"], ["aa", "cc"]] {
            let prepared = try await preparation.prepare(capture(values))
            items.append(try inserted(await history.authority.commitCapture(prepared)))
        }
        let prepared = try await preparation.prepare(capture(["bb", "aa"]))
        let receipt = try await history.authority.commitCapture(prepared)
        guard case .committed(let commit) = receipt, case .coalesced(let winner) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(winner == items[1])
        #expect(try await history.browse(.init(kind: .recent, limit: 10)).rows.count == 3)
    }

    @Test func canonicalSubsetMatchingRetainsEachItemsRepresentations() async throws {
        let history = try await WSSupport.makeHistory()
        let plain = capture(["alpha", "beta"])
        let original = try inserted(await history.perform(.capture(ClipboardCapture(
            representations: plain.representations + [
                CapturedRepresentation(typeIdentifier: "public.html", bytes: Data("<b>beta</b>".utf8),
                                       pasteboardItemIndex: 1),
            ], origin: plain.origin, observedAt: plain.observedAt
        ))))
        let receipt = try await history.perform(.capture(plain))
        guard case .committed(let commit) = receipt, case .coalesced(let winner) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(winner == original)
        let payload = try await history.pastePayload(for: original.id)
        #expect(payload.representations.map(\.pasteboardItemIndex) == [0, 1, 1])
        #expect(payload.representations.map(\.typeIdentifier) == [type, "public.html", type])
    }

    @Test func revisionAndReopenPreserveIndependentSameTypePayloadsAndExactReads() async throws {
        let url = WSSupport.tempStoreURL("sqlite-multi-item-reopen")
        defer { WSSupport.removeStore(url) }
        let current = try await seedRevisionAndRelease(at: url)
        let history = try await WSSupport.openHistory(storeURL: url)
        let payload = try await history.pastePayload(for: current.id)
        #expect(payload.item == current)
        #expect(payload.representations.map(\.pasteboardItemIndex) == [0, 1])
        #expect(payload.representations.map(\.bytes) == [largeFirst, Data("edited beta".utf8)])
        let details = try await history.details(for: current.id)
        #expect(details.canonical.map(\.pasteboardItemIndex) == [0, 1])
        #expect(details.effective.map(\.pasteboardItemIndex) == [0, 1])
        #expect(details.canonical.map(\.byteCount) == [largeFirst.count, largeSecond.count])
        #expect(details.effective.map(\.byteCount) == [largeFirst.count, "edited beta".utf8.count])
        #expect(details.revisions.count == 1)
        #expect(details.revisions.first?.typeIdentifiers == [type])
        let canonicalSecond = try await history.representation(HistoryRepresentationRequest(
            item: current, basis: .canonical, typeIdentifier: type, pasteboardItemIndex: 1
        ))
        #expect(canonicalSecond.pasteboardItemIndex == 1)
        #expect(canonicalSecond.bytes == largeSecond)
        let effectiveSecond = try await history.representation(HistoryRepresentationRequest(
            item: current, basis: .effective, typeIdentifier: type, pasteboardItemIndex: 1
        ))
        #expect(effectiveSecond.bytes == Data("edited beta".utf8))
        let hinted = capture([String(decoding: largeFirst, as: UTF8.self), "edited beta"], hint: current.id)
        let receipt = try await history.perform(.capture(hinted))
        guard case .committed(let commit) = receipt, case .coalesced(let winner) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(winner == current)
    }

    @Test func storedRevisionCannotDropTheLastPasteboardItem() async throws {
        let history = try await WSSupport.makeHistory()
        let original = try inserted(await history.perform(.capture(capture(["alpha", "beta"]))))
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: original.id, expected: original.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: type, action: .replace(bytes: Data("edited".utf8))),
                RevisionDecision(typeIdentifier: type, action: .inheritCanonical, pasteboardItemIndex: 1),
            ]))
        )))
        guard case .committed(let commit) = receipt, case .revised(let current) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        try await history.authority.withTestDatabase { authority in
            try authority.database.writeTransaction {
                try authority.database.execute("""
                    DELETE FROM representations
                    WHERE contentID = (SELECT currentContentID FROM history_items WHERE id = ?)
                      AND pasteboardItemIndex = 1
                    """, bindings: [.text(current.id.rawValue.uuidString)])
                try authority.database.execute("""
                    UPDATE contents SET representationCount = 1, contentByteCount = 6
                    WHERE id = (SELECT currentContentID FROM history_items WHERE id = ?)
                    """, bindings: [.text(current.id.rawValue.uuidString)])
                try authority.database.execute("UPDATE history_items SET revisionBytes = 6 WHERE id = ?",
                    bindings: [.text(current.id.rawValue.uuidString)])
            }
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.details(for: current.id)
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.pastePayload(for: current.id)
        }
    }

    @Test(arguments: [0, 2])
    func noncontiguousStoredItemIndicesFailDetailsAndPaste(index: Int) async throws {
        let history = try await WSSupport.makeHistory()
        let item = try inserted(await history.perform(.capture(ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: "public.html", bytes: Data("first".utf8)),
                CapturedRepresentation(typeIdentifier: type, bytes: Data("second".utf8), pasteboardItemIndex: 1),
            ], origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 900_000_000)
        ))))
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("""
                UPDATE representations SET pasteboardItemIndex = ?
                WHERE contentID = (SELECT currentContentID FROM history_items WHERE id = ?)
                  AND ordinal = ?
                """, bindings: [.integer(Int64(index == 0 ? 1 : index)),
                                 .text(item.id.rawValue.uuidString), .integer(Int64(index == 0 ? 0 : 1))])
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.details(for: item.id)
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.pastePayload(for: item.id)
        }
    }

    private var largeFirst: Data { Data(repeating: 0x61, count: 70_000) }
    private var largeSecond: Data { Data(repeating: 0x62, count: 70_000) }

    private func seedRevisionAndRelease(at url: URL) async throws -> HistoryItemReference {
        let history = try await WSSupport.openHistory(storeURL: url)
        let original = try inserted(await history.perform(.capture(capture([
            String(decoding: largeFirst, as: UTF8.self), String(decoding: largeSecond, as: UTF8.self)
        ]))))
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: original.id, expected: original.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: type, action: .inheritCanonical),
                RevisionDecision(typeIdentifier: type, action: .replace(bytes: Data("edited beta".utf8)),
                                 pasteboardItemIndex: 1),
            ]))
        )))
        guard case .committed(let commit) = receipt, case .revised(let current) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return current
    }

    private func capture(_ texts: [String], hint: HistoryItemID? = nil) -> ClipboardCapture {
        ClipboardCapture(representations: texts.enumerated().map { index, text in
            CapturedRepresentation(typeIdentifier: type, bytes: Data(text.utf8), pasteboardItemIndex: index)
        }, origin: .init(sourceApplication: nil, lineageHint: hint),
           observedAt: Date(timeIntervalSinceReferenceDate: 900_000_001))
    }

    private func inserted(_ receipt: HistoryReceipt) throws -> HistoryItemReference {
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}
