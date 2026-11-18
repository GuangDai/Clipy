import SwiftUI

/// The floating pane reserves a narrow strip on its physical outer edge.
/// AppKit owns the frame and the saved width. This control handles focus,
/// pointer input and keyboard or accessibility adjustments.
struct PreviewWidthResizeHandle: View {
    @Environment(\.locale) private var locale
    static let thickness: CGFloat = 14
    private static let widthStep: CGFloat = 20

    let width: CGFloat
    let isOnLeftEdge: Bool
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void
    let onAdjust: (CGFloat) -> Void

    @State private var isHovered = false
    @State private var isDragging = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let _ = locale
        Capsule()
            .fill(isHovered || isDragging || isFocused ? Color.accentColor : Color.secondary.opacity(0.45))
            .frame(width: 3, height: 28)
            .frame(width: Self.thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .onHover { isHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isDragging { isFocused = true }
                        isDragging = true
                        onDragChanged()
                    }
                    .onEnded { _ in
                        isDragging = false
                        onDragEnded()
                    }
            )
            .focusable()
            .focused($isFocused)
            .onKeyPress(.leftArrow) {
                onAdjust(isOnLeftEdge ? Self.widthStep : -Self.widthStep)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                onAdjust(isOnLeftEdge ? -Self.widthStep : Self.widthStep)
                return .handled
            }
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
                case .increment: onAdjust(Self.widthStep)
                case .decrement: onAdjust(-Self.widthStep)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("clipy.preview.resize-width")
    }
}
