import Darwin
import Foundation
import HistoryCore
import SQLite3

extension HistoryAuthority {
    /// TODO map 4.10/4.11; V2-09 §6: no suspension occurs from the first
    /// metadata read through the final file copy. Capture, Gateway commits
    /// and blob cleanup all use this same actor, preserving one snapshot.
    internal func backup(
        to directory: URL, didCopyBlob: @Sendable () -> Void = {}
    ) throws -> HistoryBackupReceipt {
        try Task.checkCancellation()
        guard directory.isFileURL, !directory.path.utf8.contains(0) else {
            throw HistoryBackupFailure.invalidDestination
        }
        // A backup must outlive this store's cleanup and disposal. Resolve
        // parent aliases too: a Finder-selected symlink can point into the
        // managed blob tree even when the displayed path is elsewhere.
        let destinationPath = try backupPathComponents(directory)
        let ownedPath = try backupPathComponents(storeLocation.ownedDirectoryURL)
        guard !destinationPath.starts(with: ownedPath) else {
            throw HistoryBackupFailure.invalidDestination
        }
        // mkdir is exclusive even for an existing empty directory or symlink.
        // Only a successful creation gives this invocation cleanup ownership.
        guard Darwin.mkdir(directory.path, mode_t(0o700)) == 0 else {
            if errno == EEXIST { throw HistoryBackupFailure.destinationAlreadyExists }
            throw HistoryBackupFailure.destinationUnavailable
        }
        let files = FileManager()
        var complete = false
        defer { if !complete { try? files.removeItem(at: directory) } }
        do {
            let state = try database.prepare("""
                SELECT changePosition, retainedItemCount FROM history_state WHERE key = ?
                """, bindings: [.text(Self.positionSingletonKey)])
            defer { state.finalize() }
            guard try state.step(), let count = Int(exactly: try state.integer(at: 1)), count >= 0 else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            let receipt = HistoryBackupReceipt(
                position: ChangePosition(rawValue: try sqliteUInt64(state.blob(at: 0))),
                retainedItemCount: count
            )
            state.finalize()
            try database.backup(to: directory.appendingPathComponent("history.sqlite"))
            let content = directory.appendingPathComponent("history.sqlite-content", isDirectory: true)
            try files.createDirectory(at: content.appendingPathComponent("blobs"), withIntermediateDirectories: true)
            try files.createDirectory(at: content.appendingPathComponent("staging"), withIntermediateDirectories: false)
            var after: String?
            while true {
                try Task.checkCancellation()
                // The existing blob index supplies distinct shared references
                // in bounded pages. No complete set of IDs or content is held.
                let batch = try database.prepare("""
                    SELECT blobID, MIN(byteCount), MAX(byteCount) FROM representations
                    WHERE blobID IS NOT NULL \(after == nil ? "" : "AND blobID > ?")
                    GROUP BY blobID ORDER BY blobID LIMIT 64
                    """, bindings: after.map { [.text($0)] } ?? [])
                defer { batch.finalize() }
                var visited = 0
                while try batch.step() {
                    try Task.checkCancellation()
                    let name = try batch.text(at: 0)
                    guard let id = UUID(uuidString: name),
                          let byteCount = Int(exactly: try batch.integer(at: 1)),
                          byteCount > 0, try batch.integer(at: 2) == Int64(byteCount) else {
                        throw HistoryFailure.persistence(.corruptStoredValue)
                    }
                    let relative = "blobs/\(id.uuidString.prefix(2))/\(id.uuidString).blob"
                    let source = storeLocation.rootURL.appendingPathComponent(relative)
                    let target = content.appendingPathComponent(relative)
                    // Detect missing/truncated sources without hydrating them.
                    let properties: URLResourceValues
                    do {
                        properties = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    } catch {
                        throw HistoryFailure.persistence(.corruptStoredValue)
                    }
                    guard properties.isRegularFile == true, properties.fileSize == byteCount else {
                        throw HistoryFailure.persistence(.corruptStoredValue)
                    }
                    try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try files.copyItem(at: source, to: target)
                    // A synchronous test hook exercises cancellation after
                    // real files exist without introducing actor reentrancy.
                    didCopyBlob()
                    try Task.checkCancellation()
                    after = name
                    visited += 1
                }
                if visited < 64 { break }
            }
            try Task.checkCancellation()
            complete = true
            return receipt
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as HistoryFailure {
            throw failure
        } catch let failure as SQLiteFailure where failure.primaryCode == SQLITE_CORRUPT || failure.primaryCode == SQLITE_NOTADB {
            throw HistoryFailure.persistence(.corruptStoredValue)
        } catch {
            throw HistoryBackupFailure.writeFailed
        }
    }

    /// realpath resolves existing filesystem aliases consistently, including
    /// macOS /var → /private/var. A new export has no leaf to resolve yet:
    /// resolve its existing parent and append that leaf without Foundation's
    /// path standardization rewriting one spelling independently of the other.
    /// mkdir below also requires this parent to exist.
    private func backupPathComponents(_ directory: URL) throws -> [String] {
        if let resolved = Darwin.realpath(directory.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved).split(separator: "/").map(String.init)
        }
        let parent = directory.deletingLastPathComponent()
        guard let resolved = Darwin.realpath(parent.path, nil) else {
            throw HistoryBackupFailure.destinationUnavailable
        }
        defer { free(resolved) }
        return String(cString: resolved).split(separator: "/").map(String.init)
            + [directory.lastPathComponent]
    }
}
