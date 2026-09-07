import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SQLiteContentReadValidationTests {
    enum Damage: Sendable { case representationCount, representationBytes, payloadLength, typeOrder }

    @Test(arguments: [Damage.representationCount, .representationBytes, .payloadLength, .typeOrder])
    func invalidSelectedContentStillFailsTyped(_ damage: Damage) async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            "stored text", observedAt: Date(timeIntervalSinceReferenceDate: 850_000_000),
            extra: [(typeIdentifier: "public.rtf", bytes: Array(#"{\rtf1 stored}"#.utf8))]
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        try await history.authority.damageSelectedContent(item.id, damage: damage)
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.pastePayload(for: item.id)
        }
    }

    @Test func revisionOrderSurvivesPrunedOrdinalGaps() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let capture = try await history.perform(.capture(WSSupport.textCapture(
            "original", observedAt: Date(timeIntervalSinceReferenceDate: 850_000_000)
        )))
        guard case .committed(let commit) = capture, case .inserted(var item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        for text in ["first", "second"] {
            let receipt = try await history.perform(.revise(RevisionRequest(
                itemID: item.id, expected: item.contentVersion,
                intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                    typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data(text.utf8))
                )]))
            )))
            guard case .committed(let commit) = receipt, case .revised(let revised) = commit.outcome else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            item = revised
        }
        try await history.authority.offsetRevisionOrdinals(item.id)
        let details = try await history.details(for: item.id)
        #expect(details.revisions.map(\.title) == ["first", "second"])
        #expect(details.revisions.map(\.isActive) == [false, true])
        #expect(try await history.pastePayload(for: item.id).representations.map(\.bytes) == [Data("second".utf8)])
    }
}

private extension HistoryAuthority {
    func damageSelectedContent(_ id: HistoryItemID, damage: SQLiteContentReadValidationTests.Damage) throws {
        try database.writeTransaction {
            switch damage {
            case .representationCount:
                try database.execute("""
                    UPDATE contents SET representationCount = ? WHERE itemID = ?
                    """, bindings: [.integer(Int64(limits.maximumRepresentationsPerCaptureOrRevision + 1)), .text(id.rawValue.uuidString)])
            case .representationBytes:
                try database.execute("""
                    UPDATE representations SET byteCount = ?, inlineBytes = NULL, blobID = ?
                    WHERE contentID = (SELECT currentContentID FROM history_items WHERE id = ?) AND ordinal = 0
                    """, bindings: [.integer(Int64(limits.maximumRepresentationBytes + 1)), .text(UUID().uuidString), .text(id.rawValue.uuidString)])
            case .payloadLength:
                let shorter = try blobStore.write(Data([0x41]))
                try database.execute("""
                    UPDATE representations SET inlineBytes = NULL, blobID = ?
                    WHERE contentID = (SELECT currentContentID FROM history_items WHERE id = ?) AND ordinal = 0
                    """, bindings: [.text(shorter.id.uuidString), .text(id.rawValue.uuidString)])
            case .typeOrder:
                try database.execute("""
                    UPDATE representations SET ordinal = ordinal + 100
                    WHERE contentID = (SELECT currentContentID FROM history_items WHERE id = ?)
                    """, bindings: [.text(id.rawValue.uuidString)])
                try database.execute("""
                    UPDATE representations SET ordinal = 101 - ordinal
                    WHERE contentID = (SELECT currentContentID FROM history_items WHERE id = ?)
                    """, bindings: [.text(id.rawValue.uuidString)])
            }
        }
    }

    func offsetRevisionOrdinals(_ id: HistoryItemID) throws {
        try database.writeTransaction {
            try database.execute("""
                UPDATE contents SET revisionOrdinal = revisionOrdinal + 10
                WHERE itemID = ? AND revisionOrdinal > 0
                """, bindings: [.text(id.rawValue.uuidString)])
        }
    }
}
