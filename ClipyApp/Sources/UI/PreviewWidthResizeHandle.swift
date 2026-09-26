import SwiftUI

/// The floating pane reserves a narrow strip on its physical outer edge.
/// AppKit owns screen-coordinate resizing; this SwiftUI control owns only
/// the gesture and accessible width adjustment (V2-11 preview preferences).
struct PreviewWidthResizeHandle: View {
    @Environment(\.locale) private var locale
    static let thickness: CGFloat = 14

    let width: CGFloat
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void
    let onAdjust: (CGFloat) -> Void

    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        let _ = locale
        Capsule()
            .fill(isHovered || isDragging ? Color.accentColor : Color.secondary.opacity(0.45))
            .frame(width: 3, height: 28)
            .frame(width: Self.thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .onHover { isHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        isDragging = true
                        onDragChanged()
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragEnded()
                    }
            )
            .onDisappear {
                if isDragging {
                    isDragging = false
                    onDragEnded()
                }
            }
            .help(PreviewPresentationCopy.text("Drag to adjust preview width"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PreviewPresentationCopy.text("Preview width"))
            .accessibilityValue(Text("\(Double(width), format: .number.precision(.fractionLength(0))) pt"))
            .accessibilityHint(PreviewPresentationCopy.text("Adjusts and remembers the preview width."))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onAdjust(20)
                case .decrement: onAdjust(-20)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("clipy.preview.resize-width")
    }
}
