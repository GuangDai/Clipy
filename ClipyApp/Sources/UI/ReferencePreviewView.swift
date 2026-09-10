/// Inert URL/file-reference presentation shared by the side pane and Quick
/// Look. Address/path values remain literal selectable text; expanding the
/// full reference changes only presentation and never reads its destination.
import ContentPreview
import Foundation
import SwiftUI

struct ReferencePreviewView: View {
    let reference: PreviewReference
    var requestFileLoad: (() -> Void)? = nil
    var maximumHeight: CGFloat? = nil

    private var name: String {
        if let path = reference.filePath {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            return filename.isEmpty ? path : filename
        }
        return URL(string: reference.address, encodingInvalidCharacters: false)?.host ?? reference.address
    }

    var body: some View {
        let title = PreviewCopy.text(reference.kind == .file ? "File Reference" : "URL Reference")
        ContentFittingScrollView(maximumHeight: maximumHeight) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: reference.kind == .file ? "doc" : "link")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: name)
                            .font(.body.weight(.medium))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("clipy.preview.reference.name")
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("clipy.preview.reference.title")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let filePath = reference.filePath {
                        field(
                            label: PreviewCopy.text("File Path"), value: filePath,
                            identifier: "clipy.preview.reference.path"
                        )
                    }
                    field(
                        label: PreviewCopy.text("Address"), value: reference.address,
                        identifier: "clipy.preview.reference.address"
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(reference.kind == .file && requestFileLoad != nil
                        ? PreviewCopy.text("Only the reference is shown. Loading its contents requires confirmation.")
                        : PreviewCopy.referenceDisclosure())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("clipy.preview.reference.disclosure")
                    if reference.kind == .file, let requestFileLoad {
                        Button(PreviewCopy.text("Preview File Contents…"), action: requestFileLoad)
                            .controlSize(.small)
                            .accessibilityIdentifier("clipy.preview.file.request")
                    }
                }

                DisclosureGroup(PreviewPresentationCopy.text("Full Reference")) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let path = reference.filePath {
                            Text(verbatim: path)
                        }
                        Text(verbatim: reference.address)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("clipy.preview.reference.full")
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.preview.reference")
    }

    private func field(label: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)
        }
    }
}
