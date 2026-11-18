import SwiftUI

/// Selectable preview text shared by the floating pane and Quick Look.
struct PreviewTextBody: View {
    let segments: [Substring]
    let groups: [Range<Int>]
    var maximumHeight: CGFloat?
    var fillsAvailableHeight = false
    var matches: PreviewTextMatches? = nil
    @Environment(\.searchMatchStyle) private var searchMatchStyle
    @State private var contentHeight: CGFloat?
    @State private var activeMatch = 0
    #if DEBUG
    var onSegmentMaterialized: ((Int) -> Void)?
    var onGroupMaterialized: ((Int) -> Void)?
    #endif

    var body: some View {
        let navigationHeight = (matches?.targets.count ?? 0) > 1 ? PreviewSearchMatchNavigator.height : 0
        return ScrollViewReader { reader in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.lowerBound) { group in
                        textGroup(group).id(group.lowerBound)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    let height = geometry.size.height.rounded(.up)
                    return maximumHeight.map { min(height, max(0, $0)) } ?? height
                } action: { height in
                    guard !fillsAvailableHeight else { return }
                    guard let maximumHeight else { return }
                    let currentHeight = min(contentHeight ?? maximumHeight, max(0, maximumHeight))
                    // Long content already uses the full viewport. Refinements
                    // of its lazy height must not rebuild the visible groups.
                    guard height != currentHeight else { return }
                    contentHeight = height
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let matches, matches.targets.count > 1 {
                    PreviewSearchMatchNavigator(count: matches.targets.count, selection: activeMatch,
                        accessibilityID: "clipy.preview.matches") { index in
                        activeMatch = index
                        reader.scrollTo(matches.targets[index], anchor: .center)
                    }
                    .padding(.horizontal, 12)
                    .background(.background)
                }
            }
            .onChange(of: matches, initial: true) { _, matches in
                activeMatch = 0
                if let target = matches?.targets.first { reader.scrollTo(target, anchor: .center) }
            }
        }
        .frame(height: maximumHeight.map { maximum in
            max(0, fillsAvailableHeight ? maximum : min((contentHeight ?? maximum) + navigationHeight, maximum))
        })
    }

    private func textGroup(_ range: Range<Int>) -> some View {
        let highlights: [Int: [PreviewTextMatches.Highlight]] = Dictionary(uniqueKeysWithValues: range.compactMap { index in
            matches?.highlights[index].map { (index, $0) }
        })
        #if DEBUG
        return PreviewTextSegmentGroup(text: segments[range], highlights: highlights,
            activeMatch: highlights.isEmpty ? 0 : activeMatch, searchMatchStyle: searchMatchStyle,
            onMaterialized: onSegmentMaterialized, onGroupMaterialized: onGroupMaterialized).equatable()
        #else
        return PreviewTextSegmentGroup(text: segments[range], highlights: highlights,
            activeMatch: highlights.isEmpty ? 0 : activeMatch, searchMatchStyle: searchMatchStyle).equatable()
        #endif
    }
}

/// The renderer groups only short single-line segments. One lazy leaf owns
/// at most eight independent SwiftUI text leaves; it never joins their strings and
/// recreates an oversized combining sequence (01 §6; V2-11 text previews).
private struct PreviewTextSegmentGroup: View, Equatable {
    let text: ArraySlice<Substring>
    let highlights: [Int: [PreviewTextMatches.Highlight]]
    let activeMatch: Int
    let searchMatchStyle: SearchMatchStyle
    #if DEBUG
    var onMaterialized: ((Int) -> Void)?
    var onGroupMaterialized: ((Int) -> Void)?
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text.indices == rhs.text.indices
            && lhs.text.elementsEqual(rhs.text) { $0.utf8.elementsEqual($1.utf8) }
            && lhs.highlights == rhs.highlights && lhs.activeMatch == rhs.activeMatch
            && (lhs.highlights.isEmpty || lhs.searchMatchStyle == rhs.searchMatchStyle)
    }

    var body: some View {
        #if DEBUG
        onGroupMaterialized?(text.startIndex)
        for index in text.indices { onMaterialized?(index) }
        #endif
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(text.indices, id: \.self) { index in
                PreviewTextMatches.displayText(text[index], highlights: highlights[index],
                    activeMatch: activeMatch, style: searchMatchStyle)
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
