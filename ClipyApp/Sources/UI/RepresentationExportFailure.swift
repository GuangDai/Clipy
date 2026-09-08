/// File-export failures belong to the app/UI handoff, not History storage.
/// Cancelling destination selection is a successful dismissal with no file written.
enum RepresentationExportFailure: Error, Sendable, Equatable {
    case unavailable
    case writeFailed
}
