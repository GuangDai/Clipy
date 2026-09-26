import SwiftUI

/// Fit the two columns to the current window without rewriting the preferred
/// width. A temporarily narrow window can recover that preference when widened.
struct HistoryWorkspaceSplitGeometry: Equatable {
    let listWidth: Double
    let dividerWidth: Double
    let previewWidth: Double

    init(preferredListWidth: Double, availableWidth: Double) {
        let available = availableWidth.isFinite ? max(0, availableWidth) : 0
        dividerWidth = min(8, available)
        let content = available - dividerWidth
        let minimum = min(260, content / 2)
        let preferred = preferredListWidth.isFinite ? preferredListWidth : minimum
        listWidth = min(max(preferred, minimum), content - minimum)
        previewWidth = content - listWidth
    }
}

/// Settings owns the persisted binding; the divider owns only its active drag.
struct HistoryWorkspaceSplitView<ListContent: View, PreviewContent: View>: View {
    @Binding private var listWidth: Double
    @Environment(\.locale) private var locale
    @GestureState private var dragTranslation: CGFloat = 0
    private let list: ListContent
    private let preview: PreviewContent

    init(listWidth: Binding<Double>, @ViewBuilder list: () -> ListContent,
         @ViewBuilder preview: () -> PreviewContent) {
        _listWidth = listWidth
        self.list = list()
        self.preview = preview()
    }

    var body: some View {
        GeometryReader { geometry in
            let available = Double(geometry.size.width)
            let base = HistoryWorkspaceSplitGeometry(preferredListWidth: listWidth, availableWidth: available)
            let layout = HistoryWorkspaceSplitGeometry(preferredListWidth: base.listWidth + Double(dragTranslation),
                                                       availableWidth: available)
            HStack(spacing: 0) {
                list.frame(width: layout.listWidth).frame(maxHeight: .infinity).clipped()
                Rectangle().fill(Color.secondary.opacity(0.35))
                    .frame(width: 1).frame(width: layout.dividerWidth).frame(maxHeight: .infinity)
                    .contentShape(Rectangle()).pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .updating($dragTranslation) { value, translation, _ in translation = value.translation.width }
                        .onEnded { value in
                            resize(to: base.listWidth + Double(value.translation.width), available: available)
                        })
                    .focusable()
                    .onKeyPress(.leftArrow) { resize(to: base.listWidth - 20, available: available); return .handled }
                    .onKeyPress(.rightArrow) { resize(to: base.listWidth + 20, available: available); return .handled }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text("History list width"))
                    .accessibilityValue(Text("\(layout.listWidth, format: .number.precision(.fractionLength(0))) pt"))
                    .accessibilityHint(text("Drag or use the arrow keys to resize the history list."))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: resize(to: base.listWidth + 20, available: available)
                        case .decrement: resize(to: base.listWidth - 20, available: available)
                        @unknown default: break
                        }
                    }
                    .accessibilityIdentifier("clipy.history.workspace.resize-list")
                preview.frame(width: layout.previewWidth).frame(maxHeight: .infinity).clipped()
            }
        }
    }

    private func resize(to preferred: Double, available: Double) {
        let current = HistoryWorkspaceSplitGeometry(preferredListWidth: listWidth, availableWidth: available).listWidth
        let resized = HistoryWorkspaceSplitGeometry(preferredListWidth: preferred, availableWidth: available).listWidth
        if resized != current { listWidth = resized }
    }

    private func text(_ key: String) -> String {
        HistoryWorkspaceCopy.text(key, bundle: PanelActionsCopy.bundle(for: locale))
    }
}
