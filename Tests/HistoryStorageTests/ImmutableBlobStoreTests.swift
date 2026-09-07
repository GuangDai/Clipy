import Darwin
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// Real files exercise the same concrete implementation used by Authority.
/// V2-09 §§5/6: immutable publication, corruption rejection and bounded GC.
struct ImmutableBlobStoreTests {
    @Test(arguments: [false, true])
    func synchronizationFailureCannotReturnAPublishedReference(fully: Bool) throws {
        try withStore { _, root in
            var directorySyncs = 0
            let store = try ImmutableBlobStore(root: root) { descriptor, full in
                if !full { directorySyncs += 1 }
                // Two initialization directories, then the blobs parent,
                // then the shard containing the newly published entry.
                if (fully && full) || (!fully && directorySyncs == 4) {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
                }
                let result = full ? Darwin.fcntl(descriptor, F_FULLFSYNC) : Darwin.fsync(descriptor)
                guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
            let id = UUID()
            #expect(throws: HistoryFailure.persistence(.transaction)) {
                try store.write(Data("must not become a SQL reference".utf8), id: id)
            }
            #expect(!FileManager.default.fileExists(atPath: stagingURL(root, id).path))
            #expect(FileManager.default.fileExists(atPath: blobURL(root, id).path))
            // Publication happened before failure. Its unreferenced file is
            // reclaimed normally; no old or referenced content was removed.
            var removed = 0
            for _ in 0..<4 { removed += try store.cleanupBatch(limit: 8) { _ in false } }
            #expect(removed == 1)
        }
    }

    @Test(.enabled(if: geteuid() != 0, "Access-denial behavior requires a non-root process"))
    func unreadableExistingFileIsAnIOFailureNotCorruption() throws {
        try withStore { store, root in
            let reference = try store.write(Data(repeating: 7, count: 100))
            let url = blobURL(root, reference.id)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            #expect(throws: HistoryFailure.persistence(.transaction)) {
                try store.read(id: reference.id, expectedByteCount: reference.byteCount)
            }
            #expect(throws: HistoryFailure.persistence(.transaction)) {
                try store.read(id: reference.id, expectedByteCount: reference.byteCount, range: 0..<10)
            }
        }
    }

    @Test
    func publishedBytesAndRangesAreExact() throws {
        try withStore { store, _ in
            let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
            let reference = try store.write(bytes)
            #expect(reference.byteCount == bytes.count)
            #expect(try store.read(id: reference.id, expectedByteCount: bytes.count) == bytes)
            let range = 53..<180_053
            #expect(try store.read(id: reference.id, expectedByteCount: bytes.count, range: range) == bytes.subdata(in: range))
            #expect(try store.read(id: reference.id, expectedByteCount: bytes.count, range: 50..<50).isEmpty)
        }
    }

    @Test
    func duplicateIdentityNeverOverwritesPublishedContent() throws {
        try withStore { store, root in
            let original = Data("original immutable value".utf8)
            let reference = try store.write(original)
            #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
                try store.write(Data("replacement".utf8), id: reference.id)
            }
            #expect(try store.read(id: reference.id, expectedByteCount: original.count) == original)
            #expect(!FileManager.default.fileExists(atPath: stagingURL(root, reference.id).path))
        }
    }

    @Test
    func missingTruncatedAndInvalidRangeAreTypedFailures() throws {
        try withStore { store, root in
            #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                try store.read(id: UUID(), expectedByteCount: 10)
            }
            let reference = try store.write(Data(repeating: 7, count: 100))
            #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                try store.read(id: reference.id, expectedByteCount: 100, range: 0..<101)
            }
            let file = try FileHandle(forWritingTo: blobURL(root, reference.id))
            try file.truncate(atOffset: 20)
            try file.close()
            #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                try store.read(id: reference.id, expectedByteCount: 100)
            }
            #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                try store.read(id: reference.id, expectedByteCount: 100, range: 0..<10)
            }
        }
    }

    @Test
    func failedPublicationRemovesOnlyItsOwnStagingFile() throws {
        try withStore { store, root in
            let id = UUID()
            let blockedParent = root.appendingPathComponent("blobs/\(id.uuidString.prefix(2))")
            try Data("not a directory".utf8).write(to: blockedParent)
            #expect(throws: HistoryFailure.persistence(.transaction)) {
                try store.write(Data(repeating: 2, count: 100), id: id)
            }
            #expect(!FileManager.default.fileExists(atPath: stagingURL(root, id).path))
            #expect(try Data(contentsOf: blockedParent) == Data("not a directory".utf8))
        }
    }

    @Test
    func existingStagingFileIsNeitherOverwrittenNorRemovedByFailedWrite() throws {
        try withStore { store, root in
            let id = UUID()
            let existing = Data("unfinished earlier write".utf8)
            try existing.write(to: stagingURL(root, id))
            #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
                try store.write(Data("later write".utf8), id: id)
            }
            #expect(try Data(contentsOf: stagingURL(root, id)) == existing)
        }
    }

    @Test
    func cleanupPreservesReferencesAndReclaimsUncommittedFilesInBoundedBatches() throws {
        try withStore { store, root in
            let kept = try store.write(Data("committed".utf8))
            let orphan = try store.write(Data("SQL transaction rolled back".utf8))
            let abandoned = UUID()
            try Data("interrupted staging".utf8).write(to: stagingURL(root, abandoned))
            var removed = 0
            for _ in 0..<16 {
                var lookups = 0
                removed += try store.cleanupBatch(limit: 2) { id in
                    lookups += 1
                    return id == kept.id
                }
                #expect(lookups <= 2)
            }
            #expect(removed == 2)
            #expect(try store.read(id: kept.id, expectedByteCount: kept.byteCount) == Data("committed".utf8))
            #expect(!FileManager.default.fileExists(atPath: blobURL(root, orphan.id).path))
            #expect(!FileManager.default.fileExists(atPath: stagingURL(root, abandoned).path))
        }
    }

    @Test
    func returnedMappedOrCopiedDataSurvivesUnlink() throws {
        try withStore { store, _ in
            let original = Data(repeating: 83, count: 256 * 1_024)
            let reference = try store.write(original)
            let retained = try store.read(id: reference.id, expectedByteCount: reference.byteCount)
            try store.remove(id: reference.id)
            #expect(retained == original)
            #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                try store.read(id: reference.id, expectedByteCount: reference.byteCount)
            }
        }
    }

    private func withStore(_ body: (ImmutableBlobStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipy-immutable-blob-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(ImmutableBlobStore(root: root), root)
    }

    private func stagingURL(_ root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent("staging/\(id.uuidString).partial")
    }

    private func blobURL(_ root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent("blobs/\(id.uuidString.prefix(2))/\(id.uuidString).blob")
    }
}
