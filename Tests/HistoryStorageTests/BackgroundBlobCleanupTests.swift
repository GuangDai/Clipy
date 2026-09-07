/// Real SQLite/blob transactions with an awaited maintenance completion.
/// No polling, second writer, or extra History commit drives reclamation.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct BackgroundBlobCleanupTests {
    private static let binaryType = "org.clipy.gc-fixture.binary"
    private static let textType = "public.utf8-plain-text"
    private static let park = "blob-cleanup-batch"

    @Test
    func oneClearReclaimsMoreThanOneBatchAndPreservesSharedCurrentBlob() async throws {
        let history = try await Self.seededHistory(count: 130)
        let references = try await Self.references(in: history)
        let kept = try #require(references.first)
        _ = try await history.perform(.placePinned(kept.id, at: .first))
        let revision = RevisionRequest(itemID: kept.id, expected: kept.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: Self.binaryType, action: .inheritCanonical),
                RevisionDecision(typeIdentifier: Self.textType, action: .replace(bytes: Data("revised keeper".utf8)))
            ])))
        let revisedReceipt = try await history.perform(.revise(revision))
        guard case .committed(let revisedCommit) = revisedReceipt,
              case .revised(let revised) = revisedCommit.outcome else {
            Issue.record("Expected a real immutable revision")
            return
        }
        await history.authority.waitForBlobCleanup()
        let root = await history.authority.withTestDatabase { $0.storeLocation.rootURL }
        #expect(try Self.blobFiles(root: root).count == 130)
        let shared = try await Self.blobReferenceCounts(in: history).filter { $0.value == 2 }
        #expect(shared.count == 1)
        let sharedID = try #require(shared.keys.first)
        let payload = try await history.pastePayload(for: revised.id)
        let before = try await history.usage()

        let receipt = try await history.perform(.clear(.unpinned))
        guard case .committed(let clear) = receipt, case .cleared(let count) = clear.outcome else {
            Issue.record("Expected one public clear commit")
            return
        }
        #expect(count == 129)
        #expect(clear.position.rawValue == before.position.rawValue + 1)
        let committed = try await GatewayHistoryTestSnapshot.read(from: history.authority)
        await history.authority.waitForBlobCleanup()

        // One initiating clear and one wait, with no later capture/remove.
        #expect(try Self.blobFiles(root: root) == [sharedID])
        #expect(try await Self.blobReferenceCounts(in: history) == [sharedID: 2])
        #expect(try await history.pastePayload(for: revised.id) == payload)
        #expect(committed.items.count == 1)
        #expect(committed.items.first?.contentVersionRaw == revised.contentVersion.rawValue)
        #expect(try await GatewayHistoryTestSnapshot.read(from: history.authority) == committed)
    }

    @Test
    func clearDuringAnExistingPassRescansFilesWhoseReferencesWereAlreadyVisited() async throws {
        let history = try await Self.seededHistory(count: 130)
        let root = await history.authority.withTestDatabase { $0.storeLocation.rootURL }
        let gate = SuspensionGate()
        await Self.parkCleanup(history, at: gate)
        await history.authority.requestBlobCleanup()
        await gate.waitForPark(Self.park)
        // Let one bounded batch inspect referenced files, then stop before
        // the second batch. They become orphaned only AFTER that inspection.
        await gate.resume(Self.park)
        await gate.waitForPark(Self.park)
        do {
            #expect(try Self.blobFiles(root: root).count == 130)
            let receipt = try await history.perform(.clear(.all))
            guard case .committed(let commit) = receipt, case .cleared(let count) = commit.outcome else {
                Issue.record("Expected clear while maintenance is parked")
                await Self.resumeCleanup(history, gate: gate)
                return
            }
            #expect(count == 130)
            let committed = try await GatewayHistoryTestSnapshot.read(from: history.authority)
            await Self.resumeCleanup(history, gate: gate)
            await history.authority.waitForBlobCleanup()
            #expect(try Self.blobFiles(root: root).isEmpty)
            #expect(try await GatewayHistoryTestSnapshot.read(from: history.authority) == committed)
        } catch {
            await Self.resumeCleanup(history, gate: gate)
            await history.authority.waitForBlobCleanup()
            throw error
        }
    }

    @Test
    func rolledBackPublicationIsReclaimedWithoutChangingOldHistory() async throws {
        let history = try await Self.seededHistory(count: 1)
        let root = await history.authority.withTestDatabase { $0.storeLocation.rootURL }
        let oldFiles = try Self.blobFiles(root: root)
        let before = try await GatewayHistoryTestSnapshot.read(from: history.authority)
        let gate = SuspensionGate()
        await Self.parkCleanup(history, at: gate)
        await history.authority.setTransactionFailureInjection(.beforeHCRAppend)
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.perform(.capture(Self.capture(index: 200)))
        }
        await gate.waitForPark(Self.park)
        do {
            // The real publication happened, then its SQL transaction failed.
            #expect(try Self.blobFiles(root: root).count == oldFiles.count + 1)
            #expect(try await GatewayHistoryTestSnapshot.read(from: history.authority) == before)
            await Self.resumeCleanup(history, gate: gate)
            await history.authority.waitForBlobCleanup()
            #expect(try Self.blobFiles(root: root) == oldFiles)
            #expect(try await GatewayHistoryTestSnapshot.read(from: history.authority) == before)
        } catch {
            await Self.resumeCleanup(history, gate: gate)
            await history.authority.waitForBlobCleanup()
            throw error
        }
    }

    @Test
    func returnedPayloadRemainsValidAfterRemoveAndBackgroundUnlink() async throws {
        let history = try await Self.seededHistory(count: 1)
        let references = try await Self.references(in: history)
        let reference = try #require(references.first)
        let payload = try await history.pastePayload(for: reference.id)
        let retainedBytes = try #require(payload.representations.first { $0.typeIdentifier == Self.binaryType }?.bytes)
        #expect(retainedBytes == Self.binaryBytes(index: 0))
        let root = await history.authority.withTestDatabase { $0.storeLocation.rootURL }
        _ = try await history.perform(.remove(reference.id))
        let committed = try await GatewayHistoryTestSnapshot.read(from: history.authority)
        await history.authority.waitForBlobCleanup()
        #expect(try Self.blobFiles(root: root).isEmpty)
        #expect(retainedBytes == Self.binaryBytes(index: 0))
        #expect(try await GatewayHistoryTestSnapshot.read(from: history.authority) == committed)
    }

    @Test
    func cancellationJoinsTheQueuedTaskAndReleasesTheTemporaryStore() async throws {
        let temporaryDirectory = try await Self.cancelAndReleaseHistory()
        #expect(!FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }

    @Test
    func coldReopenReclaimsPublishedAndStagingOrphansWithoutAHistoryCommit() async throws {
        let storeURL = WSSupport.tempStoreURL("cold-blob-cleanup")
        defer { WSSupport.removeStore(storeURL) }
        let (root, before) = try await Self.createClosedEmptyStore(at: storeURL)
        let (orphanID, abandonedStaging) = try Self.writeColdOrphans(root: root)
        #expect(try Self.blobFiles(root: root) == [orphanID])
        #expect(FileManager.default.fileExists(atPath: abandonedStaging.path))

        // The first facade and its database have gone out of scope. Only
        // reopen schedules this work: no capture, removal, or manual request.
        let reopened = try await WSSupport.openHistory(storeURL: storeURL)
        await reopened.authority.waitForBlobCleanup()
        #expect(try Self.blobFiles(root: root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: abandonedStaging.path))
        #expect(try await GatewayHistoryTestSnapshot.read(from: reopened.authority) == before)
    }

    @Test
    func cancelledOldTaskCannotClearOrConsumeItsReplacementTask() async throws {
        let history = try await Self.seededHistory(count: 1)
        let root = await history.authority.withTestDatabase { $0.storeLocation.rootURL }
        let oldGate = SuspensionGate()
        let newGate = SuspensionGate()
        await Self.parkCleanup(history, at: oldGate)
        await history.authority.requestBlobCleanup()
        await oldGate.waitForPark(Self.park)
        let oldHandle = await history.authority.blobCleanupTask
        let oldTask = try #require(oldHandle)
        await history.authority.cancelBlobCleanup()
        await Self.parkCleanup(history, at: newGate)
        do {
            _ = try await history.perform(.clear(.all))
            await newGate.waitForPark(Self.park)
            let newHandle = await history.authority.blobCleanupTask
            let newTask = try #require(newHandle)
            let committed = try await GatewayHistoryTestSnapshot.read(from: history.authority)

            // Resume only the old, cancelled task. The new task remains
            // parked; neither its handle nor its pending work may be reset.
            await oldGate.resumeAll()
            await oldTask.value
            let replacementIsPending = await history.authority.blobCleanupTask != nil
            #expect(replacementIsPending)
            #expect(try Self.blobFiles(root: root).count == 1)
            await Self.resumeCleanup(history, gate: newGate)
            await newTask.value
            await history.authority.waitForBlobCleanup()
            #expect(try Self.blobFiles(root: root).isEmpty)
            #expect(try await GatewayHistoryTestSnapshot.read(from: history.authority) == committed)
        } catch {
            let pending = await history.authority.blobCleanupTask
            await history.authority.cancelBlobCleanup()
            await history.authority.setSuspensionHandler(nil)
            await oldGate.resumeAll()
            await newGate.resumeAll()
            await oldTask.value
            await pending?.value
            throw error
        }
    }

    private static func createClosedEmptyStore(at url: URL) async throws -> (URL, GatewayHistoryTestSnapshot) {
        let history = try await WSSupport.openHistory(storeURL: url)
        await history.authority.waitForBlobCleanup()
        let root = await history.authority.withTestDatabase { $0.storeLocation.rootURL }
        let snapshot = try await GatewayHistoryTestSnapshot.read(from: history.authority)
        return (root, snapshot)
    }

    private static func writeColdOrphans(root: URL) throws -> (UUID, URL) {
        let blobs = try ImmutableBlobStore(root: root)
        let orphan = try blobs.write(binaryBytes(index: 201))
        let staging = root.appendingPathComponent("staging/\(UUID().uuidString).partial")
        try Data("interrupted publication".utf8).write(to: staging)
        return (orphan.id, staging)
    }

    private static func cancelAndReleaseHistory() async throws -> URL {
        let history = try await seededHistory(count: 1)
        let root = await history.authority.withTestDatabase { $0.storeLocation.rootURL }
        let before = try await GatewayHistoryTestSnapshot.read(from: history.authority)
        let gate = SuspensionGate()
        await parkCleanup(history, at: gate)
        await history.authority.requestBlobCleanup()
        await gate.waitForPark(park)
        let pendingHandle = await history.authority.blobCleanupTask
        let pending = try #require(pendingHandle)
        await history.authority.cancelBlobCleanup()
        await resumeCleanup(history, gate: gate)
        await pending.value
        await history.authority.waitForBlobCleanup()
        #expect(try await GatewayHistoryTestSnapshot.read(from: history.authority) == before)
        #expect(try blobFiles(root: root).count == 1)
        return root.deletingLastPathComponent()
    }

    private static func seededHistory(count: Int) async throws -> SQLiteHistory {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        _ = try await history.seedPerformanceFixture(rowCount: count) { capture(index: $0) }
        await history.authority.waitForBlobCleanup()
        return history
    }

    private static func binaryBytes(index: Int) -> Data {
        Data(repeating: UInt8(index), count: 70 * 1_024)
    }

    private static func capture(index: Int) -> ClipboardCapture {
        ClipboardCapture(representations: [
            CapturedRepresentation(typeIdentifier: binaryType, bytes: binaryBytes(index: index)),
            CapturedRepresentation(typeIdentifier: textType, bytes: Data("gc item \(index)".utf8))
        ], origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
        observedAt: Date(timeIntervalSinceReferenceDate: 700_100_000 + Double(index)))
    }

    private static func references(in history: SQLiteHistory) async throws -> [HistoryItemReference] {
        try await history.authority.withTestDatabase { authority in
            let rows = try authority.database.prepare("SELECT id,contentVersion FROM history_items ORDER BY lastCopiedAt,id")
            defer { rows.finalize() }
            var result: [HistoryItemReference] = []
            while try rows.step() {
                let rawID = try rows.text(at: 0)
                let id = try #require(UUID(uuidString: rawID))
                let version = try sqliteUInt64(rows.blob(at: 1))
                result.append(HistoryItemReference(
                    id: HistoryItemID(rawValue: id),
                    contentVersion: ContentVersion(rawValue: version)))
            }
            return result
        }
    }

    private static func blobReferenceCounts(in history: SQLiteHistory) async throws -> [UUID: Int] {
        try await history.authority.withTestDatabase { authority in
            let rows = try authority.database.prepare("""
                SELECT blobID,COUNT(*) FROM representations WHERE blobID IS NOT NULL GROUP BY blobID
                """)
            defer { rows.finalize() }
            var result: [UUID: Int] = [:]
            while try rows.step() {
                let rawID = try rows.text(at: 0)
                let id = try #require(UUID(uuidString: rawID))
                let count = try Int(rows.integer(at: 1))
                result[id] = count
            }
            return result
        }
    }

    private static func blobFiles(root: URL) throws -> Set<UUID> {
        let enumerator = try #require(FileManager.default.enumerator(
            at: root.appendingPathComponent("blobs"), includingPropertiesForKeys: nil))
        var result = Set<UUID>()
        for case let url as URL in enumerator where url.pathExtension == "blob" {
            result.insert(try #require(UUID(uuidString: url.deletingPathExtension().lastPathComponent)))
        }
        return result
    }

    private static func parkCleanup(_ history: SQLiteHistory, at gate: SuspensionGate) async {
        await history.authority.setSuspensionHandler { point in
            if point == .blobCleanupBatchEntry { await gate.park(at: park) }
        }
    }

    private static func resumeCleanup(_ history: SQLiteHistory, gate: SuspensionGate) async {
        await history.authority.setSuspensionHandler(nil)
        await gate.resumeAll()
    }
}
