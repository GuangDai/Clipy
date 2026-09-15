import Foundation
import HistoryCore

/// An app-owned local-file read, invoked for a visible PDF reference or after
/// explicit confirmation for other file types. The address is the original copied file URL spelling;
/// the returned bytes are transient and never become History content. A
/// successfully rendered PDF retains this bounded immutable snapshot only
/// while its file preview is open, allowing navigation without rereads.
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
