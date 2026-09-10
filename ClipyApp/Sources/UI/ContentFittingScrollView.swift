import SwiftUI

/// A short preview takes its rendered height; a long one scrolls at the
/// available ceiling. The measurement is inside the scroll view, independent
/// of its viewport, so resizing the window cannot feed back into its height.
struct ContentFittingScrollView<Content: View>: View {
    var maximumHeight: CGFloat?
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content()
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height.rounded(.up)
                } action: { contentHeight = $0 }
        }
        .frame(height: maximumHeight.map { min(contentHeight, max(0, $0)) })
    }
}
