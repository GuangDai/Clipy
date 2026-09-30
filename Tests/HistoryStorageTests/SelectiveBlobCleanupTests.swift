import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SelectiveBlobCleanupTests {
    @Test func removalReclaimsItsReferencedFilesWithoutScanningUnknownOrphans() async throws {
        let history = try await WSSupport.makeHistory()
        let receipt = try await history.perform(.capture(capture()))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        await history.authority.waitForBlobCleanup()
        let root = await history.authority.withTestDatabase { $0.storeLocation.rootURL }
        let files = try ImmutableBlobStore(root: root)
        let orphan = try files.write(Data("unknown rollback orphan".utf8))
        let staging = root.appendingPathComponent("staging/\(UUID().uuidString).partial")
        try Data("unknown interrupted staging".utf8).write(to: staging)

        _ = try await history.perform(.remove(item.id))
        await history.authority.waitForBlobCleanup()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("staging").path).count == 1)
        #expect(FileManager.default.fileExists(atPath: blobURL(root, orphan.id).path))
        // Only the known removed blob is unlinked. Unknown files require an
        // actual startup/failed-publication request instead of an O(N) walk
        // after every unrelated single-item removal.
        #expect(blobFiles(root) == [orphan.id])
        await history.authority.requestBlobCleanup(scanningOrphans: true)
        await history.authority.waitForBlobCleanup()
        #expect(blobFiles(root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func orphanScanRequestedDuringAnOrdinaryPassIsNotLost() async throws {
        let history = try await WSSupport.makeHistory()
        await history.authority.waitForBlobCleanup()
        let root = await history.authority.withTestDatabase { $0.storeLocation.rootURL }
        let files = try ImmutableBlobStore(root: root)
        let orphan = try files.write(Data("orphan requiring a complete scan".utf8))
        let gate = SuspensionGate()
        let point = AuthoritySuspensionPoint.blobCleanupBatchEntry.rawValue
        await history.authority.setSuspensionHandler { suspension in
            if suspension == .blobCleanupBatchEntry { await gate.park(at: point) }
        }
        await history.authority.requestBlobCleanup()
        await gate.waitForPark(point)
        await history.authority.requestBlobCleanup(scanningOrphans: true)
        await history.authority.setSuspensionHandler(nil)
        await gate.resumeAll()
        await history.authority.waitForBlobCleanup()
        #expect(!FileManager.default.fileExists(atPath: blobURL(root, orphan.id).path))
        #expect(try await history.usage().itemCount == 0)
    }

    private func capture() -> ClipboardCapture {
        ClipboardCapture(representations: [
            .init(typeIdentifier: "org.clipy.selective-cleanup.binary", bytes: Data(repeating: 67, count: 70 * 1_024))
        ], origin: .init(sourceApplication: nil, lineageHint: nil),
           observedAt: Date(timeIntervalSinceReferenceDate: 700_000_000))
    }

    private func blobURL(_ root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent("blobs/\(id.uuidString.prefix(2))/\(id.uuidString).blob")
    }

    private func blobFiles(_ root: URL) -> Set<UUID> {
        let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("blobs"),
                                                       includingPropertiesForKeys: nil)
        var result = Set<UUID>()
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "blob", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                result.insert(id)
            }
        }
        return result
    }
}
