import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct HistoryBackupTests {
    @Test func backupCopiesReferencesBeyondTheFirstBoundedPage() async throws {
        let history = try await WSSupport.makeHistory()
        let root = WSSupport.tempStoreURL("backup-pages")
        defer { WSSupport.removeStore(root) }
        let destination = root.deletingLastPathComponent().appendingPathComponent("export")
        for byte in UInt8(0)..<65 {
            _ = try await history.perform(.capture(capture(byte: byte)))
        }
        #expect(try await history.backup(to: destination).retainedItemCount == 65)
        #expect(blobCount(in: destination.appendingPathComponent("history.sqlite-content")) == 65)
        let restored = try await WSSupport.openHistory(storeURL: destination.appendingPathComponent("history.sqlite"))
        let page = try await restored.browse(.init(kind: .recent, limit: 100))
        #expect(page.rows.count == 65)
        for row in page.rows {
            #expect(try await restored.pastePayload(for: row.item.id).representations.contains {
                $0.bytes.count == 128 * 1_024
            })
        }
    }

    @Test func backupReopensWithRevisionsSharedBlobsAndCollisionConfirmation() async throws {
        let sourceURL = WSSupport.tempStoreURL("backup-source")
        defer { WSSupport.removeStore(sourceURL) }
        let directory = sourceURL.deletingLastPathComponent().appendingPathComponent("backup")
        let source = try await WSSupport.openHistory(storeURL: sourceURL)
        let preparation = IngestPreparationActor(fingerprint: ForcedCollisionFingerprint.digest(of:))
        let firstCapture = capture(byte: 41)
        let secondCapture = capture(byte: 42)
        let first = try inserted(try await source.authority.commitCapture(preparation.prepare(firstCapture)))
        let second = try inserted(try await source.authority.commitCapture(preparation.prepare(secondCapture)))
        var current = first
        for text in ["older revision", "current revision"] {
            let receipt = try await source.perform(.revise(RevisionRequest(
                itemID: current.id, expected: current.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(typeIdentifier: "com.example.large", action: .inheritCanonical),
                    RevisionDecision(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data(text.utf8))),
                ]))
            )))
            guard case .committed(let commit) = receipt, case .revised(let updated) = commit.outcome else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            current = updated
        }
        _ = try await source.perform(.placePinned(first.id, at: .first))
        await source.authority.waitForBlobCleanup()
        try await source.authority.createUnreferencedBackupTestBlob()
        let before = try await source.usage()
        let details = try await source.details(for: first.id)
        let payload = try await source.pastePayload(for: first.id)
        let configuration = try await source.retentionConfiguration()
        let receipt = try await source.backup(to: directory)
        #expect(receipt == HistoryBackupReceipt(position: before.position, retainedItemCount: 2))
        #expect(try await source.usage() == before)
        #expect(blobCount(in: directory.appendingPathComponent("history.sqlite-content")) == 2)

        // Destroy original references after export: backup files are independent.
        _ = try await source.perform(.remove(first.id))
        await source.authority.waitForBlobCleanup()
        let restored = try await WSSupport.openHistory(storeURL: directory.appendingPathComponent("history.sqlite"))
        #expect(try await restored.usage() == before)
        #expect(try await restored.details(for: first.id) == details)
        #expect(try await restored.pastePayload(for: first.id) == payload)
        #expect(try await restored.retentionConfiguration() == configuration)
        let canonical = try await restored.representation(HistoryRepresentationRequest(
            item: current, basis: .canonical, typeIdentifier: "public.utf8-plain-text"
        ))
        #expect(canonical.bytes == Data("canonical".utf8))
        let repeated = try await restored.authority.commitCapture(preparation.prepare(secondCapture))
        guard case .committed(let commit) = repeated, case .coalesced(let winner) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        #expect(winner == second)
        #expect(try await restored.usage().itemCount == 2)
        let olderRevision = try #require(details.revisions.first)
        _ = try await restored.perform(.revise(RevisionRequest(
            itemID: current.id, expected: current.contentVersion,
            intent: .revert(to: .revision(olderRevision.id))
        )))
        #expect(try await restored.pastePayload(for: current.id).representations.contains {
            $0.bytes == Data("older revision".utf8)
        })
    }

    @Test func existingDestinationAndMissingParentPreserveAllExistingFiles() async throws {
        let history = try await WSSupport.makeHistory()
        let marker = WSSupport.tempStoreURL("backup-existing")
        defer { WSSupport.removeStore(marker) }
        let bytes = Data("must survive".utf8)
        try bytes.write(to: marker)
        await #expect(throws: HistoryBackupFailure.destinationAlreadyExists) {
            try await history.backup(to: marker.deletingLastPathComponent())
        }
        #expect(try Data(contentsOf: marker) == bytes)
        await #expect(throws: HistoryBackupFailure.destinationUnavailable) {
            try await history.backup(to: marker.deletingLastPathComponent().appendingPathComponent("missing/export"))
        }
        #expect(try Data(contentsOf: marker) == bytes)
    }

    @Test func backupRejectsManagedContentDirectoriesAndTheirAliases() async throws {
        let store = WSSupport.tempStoreURL("backup-managed-destination")
        defer { WSSupport.removeStore(store) }
        let history = try await WSSupport.openHistory(storeURL: store)
        let item = try inserted(try await history.perform(.capture(capture(byte: 47))))
        let owned = await history.authority.backupTestOwnedDirectory()
        let alias = store.deletingLastPathComponent().appendingPathComponent("content-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: owned)
        let destinations = [
            owned,
            owned.appendingPathComponent("export"),
            owned.appendingPathComponent("blobs/export"),
            alias.appendingPathComponent("blobs/export"),
        ]
        for destination in destinations {
            await #expect(throws: HistoryBackupFailure.invalidDestination) {
                try await history.backup(to: destination)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: owned.appendingPathComponent("export").path))
        #expect(!FileManager.default.fileExists(atPath: owned.appendingPathComponent("blobs/export").path))
        #expect(try await history.pastePayload(for: item.id).representations.contains {
            $0.bytes == Data(repeating: 47, count: 128 * 1_024)
        })
        // A sibling with the managed directory's name as a prefix is safe;
        // path components distinguish it from a descendant.
        let sibling = owned.deletingLastPathComponent().appendingPathComponent(owned.lastPathComponent + "-backup")
        #expect(try await history.backup(to: sibling).retainedItemCount == 1)
    }

    @Test func temporaryStoreBackupCannotDisappearWithItsSourceDirectory() async throws {
        let history = try await WSSupport.makeHistory()
        let owned = await history.authority.backupTestOwnedDirectory()
        let destination = owned.appendingPathComponent("export")
        await #expect(throws: HistoryBackupFailure.invalidDestination) {
            try await history.backup(to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await history.usage().itemCount == 0)
    }

    @Test func missingReferencedFileRemovesPartialBackupAndPreservesSource() async throws {
        let history = try await WSSupport.makeHistory()
        let root = WSSupport.tempStoreURL("backup-failure")
        defer { WSSupport.removeStore(root) }
        let destination = root.deletingLastPathComponent().appendingPathComponent("export")
        let item = try inserted(try await history.perform(.capture(capture(byte: 43))))
        try await history.authority.makePayloadUnavailable(
            itemID: item.id, revisionOrdinal: 0, typeIdentifier: "com.example.large"
        )
        let before = try await history.usage()
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.backup(to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await history.usage() == before)
        #expect(try await history.details(for: item.id).item == item)
    }

    @Test func cancelledBackupCreatesNoOutputAndLeavesHistoryUsable() async throws {
        let history = try await WSSupport.makeHistory()
        let root = WSSupport.tempStoreURL("backup-cancel")
        defer { WSSupport.removeStore(root) }
        let destination = root.deletingLastPathComponent().appendingPathComponent("export")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await history.backup(to: destination)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await history.usage().itemCount == 0)
        #expect(try await history.backup(to: destination).retainedItemCount == 0)
    }

    @Test func cancellationAfterCopyingARealBlobRemovesAllPartialOutput() async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await history.perform(.capture(capture(byte: 46)))
        let root = WSSupport.tempStoreURL("backup-cancel-partial")
        defer { WSSupport.removeStore(root) }
        let destination = root.deletingLastPathComponent().appendingPathComponent("export")
        let before = try await history.usage()
        let task = Task {
            try await history.authority.backup(to: destination) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try await history.usage() == before)
        #expect(try await history.backup(to: destination).retainedItemCount == 1)
    }

    @Test func concurrentCaptureAndBackupAgreeOnOneSnapshot() async throws {
        let history = try await WSSupport.makeHistory()
        let root = WSSupport.tempStoreURL("backup-concurrent")
        defer { WSSupport.removeStore(root) }
        let destination = root.deletingLastPathComponent().appendingPathComponent("export")
        _ = try await history.perform(.capture(capture(byte: 44)))
        async let backup = history.backup(to: destination)
        async let captureReceipt = history.perform(.capture(capture(byte: 45)))
        let (receipt, _) = try await (backup, captureReceipt)
        let restored = try await WSSupport.openHistory(storeURL: destination.appendingPathComponent("history.sqlite"))
        let page = try await restored.browse(.init(kind: .recent, limit: 10))
        #expect(page.position == receipt.position)
        #expect(page.rows.count == receipt.retainedItemCount)
        #expect([1, 2].contains(receipt.retainedItemCount))
        for row in page.rows {
            #expect(try await restored.pastePayload(for: row.item.id).representations.count == 2)
        }
        #expect(try await history.usage().itemCount == 2)
    }

    private func capture(byte: UInt8) -> ClipboardCapture {
        ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: "com.example.large", bytes: Data(repeating: byte, count: 128 * 1_024)),
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("canonical".utf8)),
            ], origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 850_000_000)
        )
    }

    private func inserted(_ receipt: HistoryReceipt) throws -> HistoryItemReference {
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }

    private func blobCount(in root: URL) -> Int {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var count = 0
        while let file = files?.nextObject() as? URL {
            if file.pathExtension == "blob" { count += 1 }
        }
        return count
    }
}

private extension HistoryAuthority {
    func backupTestOwnedDirectory() -> URL { storeLocation.ownedDirectoryURL }

    func createUnreferencedBackupTestBlob() throws {
        _ = try blobStore.write(Data(repeating: 99, count: 128 * 1_024))
    }
}
