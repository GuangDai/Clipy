/// Inert URL/file-reference presentation shared by the side pane and Quick
/// Look through HistoryPreviewView. All address/path values are literal,
/// selectable text. The optional file action only requests confirmation;
/// file access belongs to the app-owned callback after that confirmation.
import ContentPreview
import SwiftUI

struct ReferencePreviewView: View {
    let reference: PreviewReference
    var requestFileLoad: (() -> Void)? = nil

    var body: some View {
        let title = PreviewCopy.text(reference.kind == .file ? "File Reference" : "URL Reference")
        ScrollView {
            VStack(alignment: .leading, spacing: PanelTheme.spacingLarge) {
                Label(
                    title,
                    systemImage: reference.kind == .file ? "doc" : "link"
                )
                .font(.headline)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
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

                Text(reference.kind == .file && requestFileLoad != nil
                    ? PreviewCopy.text("Only the reference is shown. Loading its contents requires confirmation.")
                    : PreviewCopy.referenceDisclosure())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("clipy.preview.reference.disclosure")
                if reference.kind == .file, let requestFileLoad {
                    Button(PreviewCopy.text("Preview File Contents…"), action: requestFileLoad)
                        .accessibilityIdentifier("clipy.preview.file.request")
                }
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
