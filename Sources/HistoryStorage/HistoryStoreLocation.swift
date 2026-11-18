import Darwin
import Foundation
import HistoryCore

/// A store's immutable location and, for disposable stores, its directory
/// lifetime. Every writer/read connection retains this value through close;
/// statements retain their connection. Releasing the facade or actor cannot
/// unlink files while SQLite still uses them (V2-09 §4–§6). No database handle
/// crosses an actor.
internal final class HistoryStoreLocation: Sendable {
    internal let databaseURL: URL
    internal let rootURL: URL
    private let disposableRoot: URL?

    /// Files below this directory can be removed by blob cleanup or by a
    /// temporary store's lifetime. Independent backups must live elsewhere.
    internal var ownedDirectoryURL: URL { disposableRoot ?? rootURL }

    internal init(persistence: HistoryPersistence) throws {
        switch persistence {
        case .persistent(let storeURL):
            // Native file/SQLite APIs consume NUL-terminated paths. Reject a
            // path they would truncate before deriving its blob namespace.
            // The legacy .path property can already truncate a decoded NUL;
            // inspect the full decoded URL path before filesystem conversion.
            guard storeURL.isFileURL, !storeURL.path(percentEncoded: false).utf8.contains(0) else {
                throw HistoryFailure.persistence(.openStore)
            }
            databaseURL = storeURL.standardizedFileURL
            // Two database files in one directory must never share a blob
            // namespace: each cleanup checks only its own database references.
            rootURL = databaseURL.deletingLastPathComponent().appendingPathComponent(
                databaseURL.lastPathComponent + "-content", isDirectory: true
            )
            disposableRoot = nil
        case .temporary:
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Clipy-History-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw HistoryFailure.persistence(.openStore)
            }
            rootURL = directory.appendingPathComponent("content", isDirectory: true)
            databaseURL = directory.appendingPathComponent("history.sqlite")
            disposableRoot = directory
        }
    }

    /// A missing or empty database may be initialized only when no companion
    /// files survive. Bootstrap would otherwise treat their content as orphaned.
    internal func permitsDatabaseCreation() throws -> Bool {
        guard disposableRoot == nil else { return true }
        let databasePath = databaseURL.path
        var status = stat()
        let databaseExists = Darwin.lstat(databasePath, &status) == 0
        guard databaseExists || errno == ENOENT else {
            throw HistoryFailure.persistence(.openStore)
        }
        if databaseExists && status.st_size > 0 { return false }

        for path in [rootURL.path, databasePath + "-wal", databasePath + "-shm", databasePath + "-journal"] {
            guard Darwin.lstat(path, &status) != 0, errno == ENOENT else {
                throw HistoryFailure.persistence(.openStore)
            }
        }
        return !databaseExists
    }

    /// A cancelled first startup can leave these two directories empty. Any
    /// entry inside them may belong to an earlier database and must survive.
    internal func requireEmptyContentDirectories() throws {
        guard disposableRoot == nil else { return }
        for name in ["blobs", "staging"] {
            let directory = rootURL.appendingPathComponent(name, isDirectory: true)
            var status = stat()
            if Darwin.lstat(directory.path, &status) != 0 {
                guard errno == ENOENT else { throw HistoryFailure.persistence(.openStore) }
                continue
            }
            var enumerationFailed = false
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  let entries = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: nil,
                    options: .skipsSubdirectoryDescendants,
                    errorHandler: { _, _ in
                        enumerationFailed = true
                        return false
                    }
                  ), entries.nextObject() == nil, !enumerationFailed else {
                throw HistoryFailure.persistence(.openStore)
            }
        }
    }

    deinit {
        // Only the unique directory created above is eligible. A caller's
        // persistent location is never removed, including on open failure.
        if let disposableRoot {
            try? FileManager.default.removeItem(at: disposableRoot)
        }
    }
}
