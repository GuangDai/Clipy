/// Inert URL/file-reference presentation shared by the side pane and Quick
/// Look through HistoryPreviewView. All address/path values are literal,
/// selectable text; no link, file accessor, or destination opener is created.
import ContentPreview
import SwiftUI

struct ReferencePreviewView: View {
    let reference: PreviewReference

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PanelTheme.spacingLarge) {
                Label(
                    PreviewCopy.text(reference.kind == .file ? "File Reference" : "URL Reference"),
                    systemImage: reference.kind == .file ? "doc" : "link"
                )
                .font(.headline)
                .accessibilityIdentifier("clipy.preview.reference.title")

                if let filePath = reference.filePath {
                    field(
                        label: PreviewCopy.text("File Path"),
                        value: filePath,
                        identifier: "clipy.preview.reference.path"
                    )
                }
                field(
                    label: PreviewCopy.text("Address"),
                    value: reference.address,
                    identifier: "clipy.preview.reference.address"
                )

                Text(PreviewCopy.referenceDisclosure())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("clipy.preview.reference.disclosure")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PanelTheme.spacingLarge)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.preview.reference")
    }

    private func field(label: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: PanelTheme.spacingXSmall) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)
        }
    }
}
