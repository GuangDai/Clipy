import AppKit
import SwiftUI

/// A geometry-only native view behind the row. SwiftUI List can host rows
/// separately from its background, so named SwiftUI coordinates must not be
/// compared with an NSEvent converted into that background's coordinates.
/// AppKit converts between the actual views in their shared window (01 §5.2).
struct HistoryRowDragRegion: NSViewRepresentable {
    let view: HistoryRowDragRegionView

    func makeNSView(context: Context) -> HistoryRowDragRegionView { view }
    func updateNSView(_ view: HistoryRowDragRegionView, context: Context) {}
}

@MainActor
final class HistoryRowDragRegionView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}
