/// Neutral pasteboard-access projection for the composition root.
///
/// AppKit owns the system value; callers receive this immutable Sendable value
/// so no `NSPasteboard.AccessBehavior` crosses the adapter boundary (REVIEW
/// Card 5A / CLIP-1).
import AppKit

/// The General pasteboard's current system access posture, translated at the
/// AppKit-owning adapter boundary. `unavailable` is fail-closed future/unknown
/// framework state; it never grants polling.
public enum PasteboardAccessBehavior: Sendable, Equatable {
    case systemDefault
    case ask
    case allowed
    case denied
    case unavailable

    /// The only AppKit translation switch. Internal so clients cannot pass an
    /// AppKit value back across the neutral boundary; owner tests use
    /// `@testable` to pin every documented macOS 15.4+ case.
    internal init(systemValue: NSPasteboard.AccessBehavior) {
        switch systemValue {
        case .default:
            self = .systemDefault
        case .ask:
            self = .ask
        case .alwaysAllow:
            self = .allowed
        case .alwaysDeny:
            self = .denied
        @unknown default:
            self = .unavailable
        }
    }
}

public extension PasteboardAdapter {
    /// Reads the authoritative framework value without touching pasteboard
    /// items or payload bytes. Only `.allowed` authorizes normal background
    /// polling at the app boundary; this projection itself performs no policy.
    var captureAccessBehavior: PasteboardAccessBehavior {
        PasteboardAccessBehavior(systemValue: pasteboard.accessBehavior)
    }
}
