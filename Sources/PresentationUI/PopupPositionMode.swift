/// PopupPositionMode.swift — where the floating panel appears when summoned
/// (Maccy's `PopupPosition` cases, replicated as a Foundation-only value so
/// the Settings surface can bind it without AppKit; the geometry itself
/// lives in ClipyApp, the AppKit-owning composition root — 01 §8).
import Foundation

/// The panel placement modes (Maccy `PopupPosition.swift`): at the mouse
/// cursor (Maccy's default), under the menu-bar status item, at the active
/// screen's center, or at the last dragged-to position.
public enum PopupPositionMode: String, CaseIterable, Sendable {
    /// Top edge at the mouse pointer (Maccy's default).
    case cursor
    /// Under the menu-bar status item (used for status-item clicks
    /// regardless of the configured mode — Maccy's
    /// `performStatusItemClick`).
    case statusItem
    /// Centered in the visible frame of the screen holding the pointer.
    case center
    /// The last dragged-to position, persisted as a normalized anchor.
    case lastPosition

    /// The settings-picker label.
    public var displayName: String {
        switch self {
        case .cursor: return "At Mouse Cursor"
        case .statusItem: return "Under Menu Bar Icon"
        case .center: return "At Screen Center"
        case .lastPosition: return "At Last Position"
        }
    }
}
