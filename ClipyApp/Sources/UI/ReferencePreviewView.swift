/// Inert URL/file-reference presentation shared by the side pane and Quick
/// Look. Address/path values remain literal selectable text; expanding the
/// full reference changes only presentation and never reads its destination.
import ContentPreview
import Foundation
import SwiftUI

struct ReferencePreviewView: View {
    @Environment(\.locale) private var locale
    let reference: PreviewReference
    var requestFileLoad: (() -> Void)? = nil
    var maximumHeight: CGFloat? = nil

    var body: some View {
        let _ = locale
        let title = PreviewCopy.text(reference.kind == .file ? "File Reference" : "URL Reference")
        ContentFittingScrollView(maximumHeight: maximumHeight) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: reference.kind == .file ? "doc" : "link")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        ReferencePreviewText(
                            value: reference.displayName, identifier: "clipy.preview.reference.name",
                            maximumNumberOfLines: 2, usesTitleStyle: true
                        )
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
                    Text(disclosure)
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
                    FullReferencePreviewContent(reference: reference)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.preview.reference.full"))
            }
            .frame(maxWidth: 600, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.preview.reference")
    }

    private var disclosure: String {
        guard reference.kind == .file, requestFileLoad != nil else {
            return PreviewCopy.referenceDisclosure()
        }
        return PreviewCopy.text("Only the reference is shown. Loading its contents requires confirmation.")
    }

    private func field(label: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ReferencePreviewText(
                value: value, identifier: identifier, maximumNumberOfLines: 2
            )
                .help(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The disclosure's complete selectable spelling, also exercised directly by
/// the hosted layout test. It owns no expansion state or destination I/O.
struct FullReferencePreviewContent: View {
    let reference: PreviewReference

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let path = reference.filePath {
                ReferencePreviewText(
                    value: path, identifier: "clipy.preview.reference.full.path"
                )
            }
            ReferencePreviewText(
                value: reference.address, identifier: "clipy.preview.reference.full.address"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
}

/// Literal text prevents Markdown/link detection and keeps the address inert.
/// Display and selection share one SwiftUI layout, including the full spelling
/// behind the two-line summary's middle truncation.
private struct ReferencePreviewText: View {
    let value: String
    let identifier: String
    var maximumNumberOfLines = 0
    var usesTitleStyle = false

    var body: some View {
        Text(verbatim: value)
            .font(usesTitleStyle
                ? .system(size: 13, weight: .medium)
                : .system(size: 11, design: .monospaced))
            .foregroundStyle(usesTitleStyle ? Color.primary : Color.secondary)
            .lineSpacing(2)
            .multilineTextAlignment(.leading)
            .lineLimit(maximumNumberOfLines == 0 ? nil : maximumNumberOfLines)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier(identifier)
    }
}
