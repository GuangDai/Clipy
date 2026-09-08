import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct RevisionCommitVersionReadTests {
    @Test func stalePreparedRevertRejectsBeforeReadingCurrentBlobAfterRetentionPrunesItsOldRevision() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .temporary, initialMaximumUnpinnedItems: nil
        ))
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [.init(typeIdentifier: "com.example.opaque", bytes: Self.bytes(0x61))],
            origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_100_000)
        )))
        guard case .committed(let captured) = receipt, case .inserted(let item) = captured.outcome else {
            Issue.record("Expected retained canonical content")
            return
        }
        _ = try await history.perform(.revise(Self.replace(item.id, expected: .initial, byte: 0x62)))
        let revert = RevisionRequest(itemID: item.id, expected: .init(rawValue: 2), intent: .revert(to: .canonical))
        let inputs = try await history.authority.revisionPreparationInputs(revert)
        let prepared = try await history.revisionPreparation.prepare(
            revert, from: inputs.snapshot, retentionPolicies: inputs.retentionPolicies
        )

        // Preparation is complete; another commit appends new Effective
        // Content and R3 removes the revision from which the revert started.
        _ = try await history.perform(.setRetentionPolicies(.init(
            age: nil, storage: nil,
            revisions: .init(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
        )))
        _ = try await history.perform(.revise(Self.replace(item.id, expected: .init(rawValue: 2), byte: 0x63)))
        let details = try await history.details(for: item.id)
        #expect(details.revisions.count == 1 && details.item.contentVersion.rawValue == 3)
        let before = try await history.usage()
        let policyBefore = try await history.retentionConfiguration()

        // The current payload is a real external blob. Removing it makes any
        // attempted payload read fail, so a stale error proves phase two
        // resolved the version using metadata before attempting content I/O.
        try await history.authority.withTestDatabase { authority in
            let row = try authority.database.prepare("""
                SELECT r.blobID FROM history_items i
                JOIN representations r ON r.contentID = i.currentContentID
                WHERE i.id = ? AND r.ordinal = 0
                """, bindings: [.text(item.id.rawValue.uuidString)])
            try #require(try row.step())
            let blob = try #require(UUID(uuidString: row.text(at: 0)))
            row.finalize()
            try authority.blobStore.remove(id: blob)
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.pastePayload(for: item.id)
        }
        await #expect(throws: HistoryFailure.staleContent(expected: .init(rawValue: 2), current: .init(rawValue: 3))) {
            try await history.authority.commitRevision(revert, prepared)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await history.authority.commitRevision(revert, prepared)
        }
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }
        let after = try await history.usage()
        #expect(after.position == before.position && after.itemCount == before.itemCount)
        #expect(after.canonicalBytes == before.canonicalBytes && after.revisionBytes == before.revisionBytes)
        #expect(try await history.retentionConfiguration() == policyBefore)

        // Removal still has precedence over the obsolete expected version.
        _ = try await history.perform(.remove(item.id))
        let removedPosition = try await history.usage().position
        await #expect(throws: HistoryFailure.notFound(item.id)) {
            try await history.authority.commitRevision(revert, prepared)
        }
        #expect(try await history.usage().position == removedPosition)
    }

    private static func bytes(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 65_537)
    }

    private static func replace(_ item: HistoryItemID, expected: ContentVersion, byte: UInt8) -> RevisionRequest {
        .init(itemID: item, expected: expected, intent: .replace(.init(decisions: [
            .init(typeIdentifier: "com.example.opaque", action: .replace(bytes: bytes(byte)))
        ])))
    }
}
