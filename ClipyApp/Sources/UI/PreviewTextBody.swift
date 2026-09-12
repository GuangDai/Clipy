import SwiftUI

/// Selectable preview text shared by the floating pane and Quick Look.
struct PreviewTextBody: View {
    let segments: [Substring]
    var maximumHeight: CGFloat?
    @State private var contentHeight: CGFloat?
    #if DEBUG
    var onSegmentMaterialized: ((Int) -> Void)?
    #endif

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(segments.indices, id: \.self) { index in
                    textSegment(index)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .onGeometryChange(for: CGFloat.self) { geometry in
                let height = geometry.size.height.rounded(.up)
                return maximumHeight.map { min(height, max(0, $0)) } ?? height
            } action: { height in
                guard let maximumHeight else { return }
                let currentHeight = min(contentHeight ?? maximumHeight, max(0, maximumHeight))
                // Long content already uses the full viewport. Refinements
                // of its lazy height must not rebuild the same visible Texts.
                guard height != currentHeight else { return }
                contentHeight = height
            }
        }
        // Start with a real viewport so lazy layout can materialize its first
        // screen. Short content then fits its measured height; long content
        // never requests a full-document intrinsic-size measurement.
        .frame(height: maximumHeight.map { min(contentHeight ?? $0, max(0, $0)) })
    }

    private func textSegment(_ index: Int) -> some View {
        #if DEBUG
        return PreviewTextSegment(text: segments[index], index: index,
                                  onMaterialized: onSegmentMaterialized).equatable()
        #else
        return PreviewTextSegment(text: segments[index], index: index).equatable()
        #endif
    }
}

/// Lazy layout may request a row more than once while refining the viewport.
/// Keep substring materialization and selectable Text construction inside a
/// stable leaf, so unchanged rows can reuse that work (V2-11 text previews).
private struct PreviewTextSegment: View, Equatable {
    let text: Substring
    let index: Int
    #if DEBUG
    var onMaterialized: ((Int) -> Void)?
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }

    var body: some View {
        #if DEBUG
        onMaterialized?(index)
        #endif
        return Text(verbatim: String(text))
            .font(.body)
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(index == 0
                ? "clipy.preview.text" : "clipy.preview.text.segment.\(index)")
    }
}
