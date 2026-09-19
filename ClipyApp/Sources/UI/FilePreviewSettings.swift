import Foundation
import HistoryCore

/// An app-owned local-file read after explicit confirmation. The returned
/// bytes are transient and never become History content.
struct FilePreviewSettings: Sendable {
    let load: @Sendable (String) async throws -> HistoryRepresentation

    init(load: @escaping @Sendable (String) async throws -> HistoryRepresentation) {
        self.load = load
    }
}

enum FilePreviewFailure: Error, Equatable, Sendable {
    case invalidReference
    case unavailable
    case changedDuringRead
    case permissionDenied
    case tooLarge
    case unsupported
}
