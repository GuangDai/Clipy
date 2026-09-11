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
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: {
                contentHeight = $0
            }
        }
        // Start with a real viewport so lazy layout can materialize its first
        // screen. Short content then fits its measured height; long content
        // never requests a full-document intrinsic-size measurement.
        .frame(height: maximumHeight.map { min(contentHeight ?? $0, max(0, $0)) })
    }

    private func textSegment(_ index: Int) -> some View {
        #if DEBUG
        onSegmentMaterialized?(index)
        #endif
        return Text(verbatim: String(segments[index]))
            .font(.body)
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(index == 0
                ? "clipy.preview.text" : "clipy.preview.text.segment.\(index)")
    }
}
