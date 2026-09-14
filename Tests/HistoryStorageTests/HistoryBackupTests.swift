import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct HistoryBackupTests {
    @Test func backupExcludesDetachedContentBeforeCleanupAndPreservesSharedLiveBlob() async throws {
        let history = try await WSSupport.makeHistory()
        let removedMarker = "retired-canonical-payload-must-not-be-exported-34862"
        let prunedMarker = "retired-revision-payload-must-not-be-exported-73941"
        let removed = try inserted(try await history.perform(.capture(capture(byte: 91, text: removedMarker))))
        let live = try inserted(try await history.perform(.capture(capture(byte: 90))))
        var current = live
        for text in [prunedMarker, "retained revision"] {
            let receipt = try await history.perform(.revise(.init(
                itemID: current.id, expected: current.contentVersion,
                intent: .replace(.init(decisions: [
                    .init(typeIdentifier: "com.example.large", action: .inheritCanonical),
                    .init(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data(text.utf8))),
                ]))
            )))
            guard case .committed(let commit) = receipt, case .revised(let revised) = commit.outcome else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            current = revised
        }
        let payload = try await history.pastePayload(for: live.id)
        let root = WSSupport.tempStoreURL("backup-detached-content")
        defer { WSSupport.removeStore(root) }
        let destination = root.deletingLastPathComponent().appendingPathComponent("export")
        await history.authority.waitForBlobCleanup()
        let gate = SuspensionGate()
        let point = AuthoritySuspensionPoint.blobCleanupBatchEntry.rawValue
        await history.authority.setSuspensionHandler { suspended in
            if suspended == .blobCleanupBatchEntry { await gate.park(at: suspended.rawValue) }
        }
        do {
            _ = try await history.perform(.remove(removed.id))
            await gate.waitForPark(point)
            _ = try await history.perform(.setRetentionPolicies(.init(
                age: nil, storage: nil,
                revisions: .init(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
            )))
            // Both deleted ownership forms remain physically in the source:
            // removed item ID and NULL owner on the pruned revision.
            #expect(try await history.authority.backupTestDetachedContentCount() == 2)
            #expect(blobCount(in: await history.authority.backupTestOwnedDirectory()) == 2)
            let before = try await history.usage()
            #expect(try await history.backup(to: destination).retainedItemCount == 1)
            #expect(try await history.usage() == before)
            #expect(try await history.authority.backupTestDetachedContentCount() == 2)
            #expect(blobCount(in: destination.appendingPathComponent("history.sqlite-content")) == 1)

            // Inspect before reopening History could run cleanup and hide an
            // invalid export. Both retained Canonical/current rows must remain.
            let metadata = destination.appendingPathComponent("history.sqlite")
            let exported = try SQLiteDatabase(url: metadata, readOnly: true)
            let count = try exported.prepare("SELECT COUNT(*) FROM contents")
            #expect(try count.step())
            #expect(try count.integer(at: 0) == 2)
            count.finalize()
            try exported.close()
            let bytes = try Data(contentsOf: metadata)
            #expect(bytes.range(of: Data(removedMarker.utf8)) == nil)
            #expect(bytes.range(of: Data(prunedMarker.utf8)) == nil)
            let restored = try await WSSupport.openHistory(storeURL: metadata)
            #expect(try await restored.usage() == before)
            #expect(try await restored.pastePayload(for: live.id) == payload)
            #expect(try await restored.details(for: live.id).revisions.count == 1)
            // The removed first row leaves a rowid gap. Export compaction
            // must preserve the live FTS posting's identity and exact search.
            let matches = try await restored.browse(.init(
                kind: .search(text: "retained revision", mode: .exact), limit: 10
            ))
            #expect(matches.rows.map(\.item.id) == [live.id])
        } catch {
            await history.authority.setSuspensionHandler(nil)
            await gate.resume(point)
            await history.authority.waitForBlobCleanup()
            throw error
        }
        await history.authority.setSuspensionHandler(nil)
        await gate.resume(point)
        await history.authority.waitForBlobCleanup()
    }

    @Test func finalDestinationAppearsOnlyAfterTheCompleteCopy() async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await history.perform(.capture(capture(byte: 81)))
        let root = WSSupport.tempStoreURL("backup-publication")
        defer { WSSupport.removeStore(root) }
        let parent = root.deletingLastPathComponent()
        let destination = parent.appendingPathComponent("export")
        let receipt = try await history.authority.backup(to: destination, didCopyBlob: {
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let siblings = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            #expect(siblings?.filter { $0.pathExtension == "incomplete" }.count == 1)
        })
        #expect(receipt.retainedItemCount == 1)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("history.sqlite").path))
        #expect(try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .allSatisfy { $0.pathExtension != "incomplete" })
    }

    @Test func concurrentDestinationCreationNeverOverwritesExistingFiles() async throws {
        let history = try await WSSupport.makeHistory()
        let root = WSSupport.tempStoreURL("backup-publication-race")
        defer { WSSupport.removeStore(root) }
        let destination = root.deletingLastPathComponent().appendingPathComponent("export")
        let marker = destination.appendingPathComponent("keep.txt")
        let bytes = Data("created while backup was running".utf8)
        await #expect(throws: HistoryBackupFailure.destinationAlreadyExists) {
            try await history.authority.backup(to: destination, synchronize: { url, isDirectory in
                if isDirectory && url.pathExtension == "incomplete" {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    try bytes.write(to: marker)
                }
                try HistoryAuthority.synchronizeBackupItem(url, isDirectory)
            })
        }
        #expect(try Data(contentsOf: marker) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["keep.txt"])
    }

    enum SynchronizationFailure: CaseIterable, Sendable {
        case blob, beforePublication, afterPublication
    }

    @Test(arguments: SynchronizationFailure.allCases)
    func synchronizationFailureNeverAcknowledgesSuccess(_ failure: SynchronizationFailure) async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await history.perform(.capture(capture(byte: 82)))
        let before = try await history.usage()
        let root = WSSupport.tempStoreURL("backup-sync-failure")
        defer { WSSupport.removeStore(root) }
        let parent = root.deletingLastPathComponent()
        let destination = parent.appendingPathComponent("export")
        await #expect(throws: HistoryBackupFailure.writeFailed) {
            try await history.authority.backup(to: destination, synchronize: { url, isDirectory in
                let shouldFail: Bool = switch failure {
                case .blob: url.pathExtension == "blob"
                case .beforePublication: isDirectory && url.pathExtension == "incomplete"
                case .afterPublication: url == parent
                }
                if shouldFail { throw HistoryBackupFailure.writeFailed }
                try HistoryAuthority.synchronizeBackupItem(url, isDirectory)
            })
        }
        #expect(try await history.usage() == before)
        #expect(try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .allSatisfy { $0.pathExtension != "incomplete" })
        if failure == .afterPublication {
            // Publication already made a complete copy visible. Keep it for
            // recovery even though durable publication was not acknowledged.
            let restored = try await WSSupport.openHistory(storeURL: destination.appendingPathComponent("history.sqlite"))
            #expect(try await restored.usage() == before)
            let row = try #require(try await restored.browse(.init(kind: .recent, limit: 1)).rows.first)
            #expect(try await restored.pastePayload(for: row.item.id).representations.contains {
                $0.bytes == Data(repeating: 82, count: 128 * 1_024)
            })
        } else {
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

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
        var destinations = [
            owned,
            owned.appendingPathComponent("export"),
            owned.appendingPathComponent("blobs/export"),
            alias,
            alias.appendingPathComponent("blobs/export-through-alias"),
        ]
        // On macOS the temporary directory commonly exposes /var while its
        // physical path starts with /private/var. Exercise both spellings of
        // an existing parent with a distinct, nonexistent export leaf.
        if owned.path.hasPrefix("/var/") {
            destinations.append(URL(fileURLWithPath: "/private" + owned.path)
                .appendingPathComponent("blobs/export-through-private-var"))
        } else if owned.path.hasPrefix("/private/var/") {
            destinations.append(URL(fileURLWithPath: String(owned.path.dropFirst("/private".count)))
                .appendingPathComponent("blobs/export-through-var"))
        }
        for destination in destinations {
            await #expect(throws: HistoryBackupFailure.invalidDestination) {
                try await history.backup(to: destination)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: owned.appendingPathComponent("export").path))
        #expect(!FileManager.default.fileExists(atPath: owned.appendingPathComponent("blobs/export").path))
        #expect(!FileManager.default.fileExists(atPath: owned.appendingPathComponent("blobs/export-through-alias").path))
        #expect(!FileManager.default.fileExists(atPath: owned.appendingPathComponent("blobs/export-through-private-var").path))
        #expect(!FileManager.default.fileExists(atPath: owned.appendingPathComponent("blobs/export-through-var").path))
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
            try await history.authority.backup(to: destination, didCopyBlob: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
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

    private func capture(byte: UInt8, text: String = "canonical") -> ClipboardCapture {
        ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: "com.example.large", bytes: Data(repeating: byte, count: 128 * 1_024)),
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8)),
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
    func backupTestDetachedContentCount() throws -> Int64 {
        let statement = try database.prepare("""
            SELECT COUNT(*) FROM contents c
            WHERE NOT EXISTS (SELECT 1 FROM history_items h WHERE h.id = c.itemID)
            """)
        defer { statement.finalize() }
        guard try statement.step() else { throw HistoryFailure.persistence(.invariantViolation) }
        return try statement.integer(at: 0)
    }

    func backupTestOwnedDirectory() -> URL { storeLocation.ownedDirectoryURL }

    func createUnreferencedBackupTestBlob() throws {
        _ = try blobStore.write(Data(repeating: 99, count: 128 * 1_024))
    }
}
