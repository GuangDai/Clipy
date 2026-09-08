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
            guard storeURL.isFileURL else {
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

    deinit {
        // Only the unique directory created above is eligible. A caller's
        // persistent location is never removed, including on open failure.
        if let disposableRoot {
            try? FileManager.default.removeItem(at: disposableRoot)
        }
    }
}
