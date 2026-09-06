import Foundation
import HistoryCore

/// An app-owned local-file read, invoked only after the preview's explicit
/// confirmation. The address is the original copied file URL spelling;
/// the returned bytes are transient and never become History content.
public struct FilePreviewSettings: Sendable {
    public let load: @Sendable (String) async throws -> HistoryRepresentation

    public init(load: @escaping @Sendable (String) async throws -> HistoryRepresentation) {
        self.load = load
    }
}

public enum FilePreviewFailure: Error, Equatable, Sendable {
    case invalidReference
    case unavailable
    case permissionDenied
    case tooLarge
    case unsupported
}
