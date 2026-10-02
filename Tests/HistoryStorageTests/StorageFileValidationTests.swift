import Darwin
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// Original blob bytes must come from a regular immutable file; malformed
/// filesystem entries cannot redirect content reads or become writer leases.
struct StorageFileValidationTests {
    enum Replacement: CaseIterable, Sendable {
        case symbolicLink, directory, fifo
    }

    @Test(arguments: Replacement.allCases, [false, true])
    func malformedBlobEntryIsRejected(replacement: Replacement, ranged: Bool) throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ImmutableBlobStore(root: root)
        let bytes = Data(repeating: 39, count: 100)
        let blob = try store.write(bytes)
        let url = blobURL(root, blob.id)
        try FileManager.default.removeItem(at: url)
        switch replacement {
        case .symbolicLink:
            let external = root.appendingPathComponent("external.bin")
            try bytes.write(to: external)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: external)
        case .directory:
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        case .fifo:
            try #require(Darwin.mkfifo(url.path, mode_t(0o600)) == 0)
        }
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            if ranged {
                return try store.read(id: blob.id, expectedByteCount: bytes.count, range: 4..<19)
            }
            return try store.read(id: blob.id, expectedByteCount: bytes.count)
        }
    }

    @Test func fifoCannotHoldAWriterLease() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("history.sqlite")
        let artifact = root.appendingPathComponent("history.sqlite.lease")
        try #require(Darwin.mkfifo(artifact.path, mode_t(0o600)) == 0)
        #expect(throws: HistoryFailure.persistence(.openStore)) {
            try StoreRootLease.acquire(storeURL: storeURL)
        }
        var status = stat()
        try #require(Darwin.lstat(artifact.path, &status) == 0)
        #expect(status.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
    }

    @Test func backupRejectsDecodedNULBeforeCreatingTheTruncatedDestination() async throws {
        let history = try await WSSupport.makeHistory()
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let destination = try #require(URL(
            string: parent.appendingPathComponent("export").absoluteString + "%00-other",
            encodingInvalidCharacters: false
        ))
        #expect(destination.path(percentEncoded: false).utf8.contains(0))
        await #expect(throws: HistoryBackupFailure.invalidDestination) {
            try await history.backup(to: destination)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        #expect(try await history.usage().itemCount == 0)
    }

    @Test(.enabled(if: geteuid() != 0, "Directory access-denial requires a non-root process"))
    func cleanupReportsUnreadableSubtreeAndRetriesAfterAccessIsRestored() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ImmutableBlobStore(root: root)
        let orphan = try store.write(Data("orphan after failed transaction".utf8))
        let shard = blobURL(root, orphan.id).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: shard.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shard.path) }
        #expect(throws: HistoryFailure.persistence(.transaction)) {
            for _ in 0..<8 { _ = try store.cleanupBatch(limit: 4) { _ in false } }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shard.path)
        var removed = 0
        for _ in 0..<8 { removed += try store.cleanupBatch(limit: 4) { _ in false }.removedCount }
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: blobURL(root, orphan.id).path))
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipy-file-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func blobURL(_ root: URL, _ id: UUID) -> URL {
        root.appendingPathComponent("blobs/\(id.uuidString.prefix(2))/\(id.uuidString).blob")
    }
}
