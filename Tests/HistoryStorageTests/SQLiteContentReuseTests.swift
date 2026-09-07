import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct SQLiteContentReuseTests {
    private let largeType = "com.example.large"
    private let bytes = Data(repeating: 37, count: 200_000)

    @Test
    func inheritedLargeContentSharesOneFileUntilTheLastReferenceIsRemoved() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        var reference = try await capture(history)
        reference = try await revise(history, reference, text: "one", large: .inheritCanonical)
        reference = try await revise(history, reference, text: "two", large: .inheritCanonical)
        let before = try await history.authority.contentReuseFactsForTest(reference.id, type: largeType)
        #expect(before.blobIDs.count == 3)
        #expect(Set(before.blobIDs).count == 1)
        #expect(before.fileCount == 1)
        #expect(before.revisionBytes == 2 * (bytes.count + 3))

        _ = try await history.perform(.setRetentionPolicies(HistoryRetentionPolicies(
            age: nil, storage: nil,
            revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
        )))
        await history.authority.waitForBlobCleanup()
        let pruned = try await history.authority.contentReuseFactsForTest(reference.id, type: largeType)
        #expect(pruned.blobIDs == [before.blobIDs[0], before.blobIDs[0]])
        #expect(pruned.fileCount == 1)
        #expect(pruned.revisionBytes == bytes.count + 3)
        #expect(try await history.pastePayload(for: reference.id).representations.contains { $0.bytes == bytes })

        _ = try await history.perform(.remove(reference.id))
        await history.authority.waitForBlobCleanup()
        let removed = try await history.authority.contentReuseFactsForTest(reference.id, type: largeType)
        #expect(removed.blobIDs.isEmpty)
        #expect(removed.fileCount == 0)
    }

    @Test
    func differentBytesAllocateOnceAndCurrentOrCanonicalCanThenBeReused() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        var reference = try await capture(history)
        let different = Data(repeating: 38, count: bytes.count)
        reference = try await revise(history, reference, text: "one", large: .replace(bytes: different))
        reference = try await revise(history, reference, text: "two", large: .replace(bytes: different))
        let reusedCurrent = try await history.authority.contentReuseFactsForTest(reference.id, type: largeType)
        #expect(reusedCurrent.blobIDs.count == 3)
        #expect(reusedCurrent.blobIDs[0] != reusedCurrent.blobIDs[1])
        #expect(reusedCurrent.blobIDs[1] == reusedCurrent.blobIDs[2])
        #expect(reusedCurrent.fileCount == 2)

        reference = try await revise(history, reference, text: "three", large: .inheritCanonical)
        let reusedCanonical = try await history.authority.contentReuseFactsForTest(reference.id, type: largeType)
        #expect(reusedCanonical.blobIDs.last == reusedCanonical.blobIDs.first)
        #expect(reusedCanonical.fileCount == 2)
        _ = try await history.perform(.setRetentionPolicies(HistoryRetentionPolicies(
            age: nil, storage: nil,
            revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
        )))
        await history.authority.waitForBlobCleanup()
        let pruned = try await history.authority.contentReuseFactsForTest(reference.id, type: largeType)
        #expect(pruned.fileCount == 1)
        #expect(pruned.blobIDs.count == 2)
        #expect(pruned.blobIDs[0] == pruned.blobIDs[1])
        #expect(pruned.revisionBytes == bytes.count + 5)
    }

    @Test
    func canonicalEquivalentTypeMatchesWithoutSearchingAnotherItem() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let decomposed = "com.example.cafe\u{301}"
        let composed = "com.example.caf\u{e9}"
        let reference = try await capture(history, type: decomposed)
        let candidate = ContentRepresentation(typeIdentifier: composed, bytes: bytes)
        let match = try await history.authority.reusableRepresentation(candidate, itemID: reference.id)
        #expect(match != nil)
        let unrelated = try await history.authority.reusableRepresentation(candidate, itemID: HistoryItemID(rawValue: UUID()))
        #expect(unrelated == nil)
        let facts = try await history.authority.contentReuseFactsForTest(reference.id, type: composed)
        #expect(facts.exactTypes == [decomposed])
    }

    @Test
    func missingCandidateBlobCannotBeBypassedAsANonmatch() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let reference = try await capture(history)
        let facts = try await history.authority.contentReuseFactsForTest(reference.id, type: largeType)
        let identifier = try #require(facts.blobIDs.first.flatMap(UUID.init(uuidString:)))
        try await history.authority.removeContentReuseBlobForTest(identifier)
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.authority.reusableRepresentation(
                ContentRepresentation(typeIdentifier: largeType, bytes: bytes), itemID: reference.id
            )
        }
    }

    private func capture(_ history: SQLiteHistory, type: String? = nil) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: type ?? largeType, bytes: bytes),
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("zero".utf8)),
            ], origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_093_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let reference) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return reference
    }

    private func revise(
        _ history: SQLiteHistory, _ reference: HistoryItemReference,
        text: String, large: RevisionDecisionAction
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: reference.id, expected: reference.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: largeType, action: large),
                RevisionDecision(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data(text.utf8))),
            ]))
        )))
        guard case .committed(let commit) = receipt, case .revised(let result) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return result
    }
}

private struct ContentReuseFacts: Sendable {
    let blobIDs: [String]
    let exactTypes: [String]
    let revisionBytes: Int
    let fileCount: Int
}

private extension HistoryAuthority {
    func contentReuseFactsForTest(_ itemID: HistoryItemID, type: String) throws -> ContentReuseFacts {
        let representations = try database.prepare("""
            SELECT r.blobID, r.exactType FROM representations r
            JOIN contents c ON c.id = r.contentID
            WHERE c.itemID = ? AND r.typeKey = ? ORDER BY c.revisionOrdinal
            """, bindings: [.text(itemID.rawValue.uuidString), .text(type.precomposedStringWithCanonicalMapping)])
        defer { representations.finalize() }
        var identifiers: [String] = []
        var exactTypes: [String] = []
        while try representations.step() {
            identifiers.append(try representations.text(at: 0))
            exactTypes.append(try representations.text(at: 1))
        }
        let item = try database.prepare("SELECT revisionBytes FROM history_items WHERE id = ?", bindings: [.text(itemID.rawValue.uuidString)])
        defer { item.finalize() }
        let revisionBytes: Int
        if try item.step() { revisionBytes = Int(try item.integer(at: 0)) } else { revisionBytes = 0 }
        let files = FileManager.default.enumerator(at: storeLocation.rootURL.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
        var fileCount = 0
        while let url = files?.nextObject() as? URL { if url.pathExtension == "blob" { fileCount += 1 } }
        return ContentReuseFacts(blobIDs: identifiers, exactTypes: exactTypes, revisionBytes: revisionBytes, fileCount: fileCount)
    }

    func removeContentReuseBlobForTest(_ id: UUID) throws { try blobStore.remove(id: id) }
}
