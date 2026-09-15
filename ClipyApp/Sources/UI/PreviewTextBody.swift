import SwiftUI

/// Selectable preview text shared by the floating pane and Quick Look.
struct PreviewTextBody: View {
    let segments: [Substring]
    let groups: [Range<Int>]
    var maximumHeight: CGFloat?
    @State private var contentHeight: CGFloat?
    #if DEBUG
    var onSegmentMaterialized: ((Int) -> Void)?
    var onGroupMaterialized: ((Int) -> Void)?
    #endif

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.lowerBound) { group in
                    textGroup(group)
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
                // of its lazy height must not rebuild the visible groups.
                guard height != currentHeight else { return }
                contentHeight = height
            }
        }
        .frame(height: maximumHeight.map { min(contentHeight ?? $0, max(0, $0)) })
    }

    private func textGroup(_ range: Range<Int>) -> some View {
        #if DEBUG
        return PreviewTextSegmentGroup(text: segments[range],
            onMaterialized: onSegmentMaterialized, onGroupMaterialized: onGroupMaterialized).equatable()
        #else
        return PreviewTextSegmentGroup(text: segments[range]).equatable()
        #endif
    }
}

/// The renderer groups only short single-line segments. One lazy leaf owns
/// at most eight independent SwiftUI text leaves; it never joins their strings and
/// recreates an oversized combining sequence (01 §6; V2-11 text previews).
private struct PreviewTextSegmentGroup: View, Equatable {
    let text: ArraySlice<Substring>
    #if DEBUG
    var onMaterialized: ((Int) -> Void)?
    var onGroupMaterialized: ((Int) -> Void)?
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text.indices == rhs.text.indices
            && lhs.text.elementsEqual(rhs.text) { $0.utf8.elementsEqual($1.utf8) }
    }

    var body: some View {
        #if DEBUG
        onGroupMaterialized?(text.startIndex)
        for index in text.indices { onMaterialized?(index) }
        #endif
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(text.indices, id: \.self) { index in
                Text(verbatim: String(text[index]))
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: text[index].isEmpty ? 16 : nil,
                           alignment: .topLeading)
                    .accessibilityIdentifier(index == 0
                        ? "clipy.preview.text" : "clipy.preview.text.segment.\(index)")
            }
        }
        // Selection uses the same SwiftUI text layout as display. No separate
        // field editor can substitute its font or paragraph spacing on click.
        .textSelection(.enabled)
    }
}
