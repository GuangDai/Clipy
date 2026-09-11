import SwiftUI

/// Selectable preview text shared by the floating pane and Quick Look.
struct PreviewTextBody: View {
    let text: String
    var maximumHeight: CGFloat?

    var body: some View {
        ContentFittingScrollView(maximumHeight: maximumHeight) {
            Text(verbatim: text)
                .font(.body)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .accessibilityIdentifier("clipy.preview.text")
        }
    }
}
