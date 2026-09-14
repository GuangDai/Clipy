/// Inert URL/file-reference presentation shared by the side pane and Quick
/// Look. Address/path values remain literal selectable text; expanding the
/// full reference changes only presentation and never reads its destination.
import AppKit
import ContentPreview
import Foundation
import SwiftUI

struct ReferencePreviewView: View {
    let reference: PreviewReference
    var requestFileLoad: (() -> Void)? = nil
    var maximumHeight: CGFloat? = nil

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
/// the hosted native layout test. It owns no expansion state or destination I/O.
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

/// Both collapsed and expanded references keep the entire original value in
/// one native selectable label. AppKit owns middle truncation for the two-line
/// summary and character wrapping for the full value; SwiftUI never shapes a
/// separate 16 KiB Text while negotiating the summary's intrinsic dimensions.
private struct ReferencePreviewText: NSViewRepresentable {
    let value: String
    let identifier: String
    var maximumNumberOfLines = 0
    var usesTitleStyle = false

    @MainActor
    final class Coordinator {
        var measuredSize: CGSize?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = font
        field.textColor = usesTitleStyle ? .labelColor : .secondaryLabelColor
        field.lineBreakMode = maximumNumberOfLines == 0 ? .byCharWrapping : .byTruncatingMiddle
        field.lineBreakStrategy = []
        field.maximumNumberOfLines = maximumNumberOfLines
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.font != font || field.maximumNumberOfLines != maximumNumberOfLines {
            field.font = font
            field.maximumNumberOfLines = maximumNumberOfLines
            field.lineBreakMode = maximumNumberOfLines == 0 ? .byCharWrapping : .byTruncatingMiddle
            context.coordinator.measuredSize = nil
        }
        field.textColor = usesTitleStyle ? .labelColor : .secondaryLabelColor
        field.setAccessibilityIdentifier(identifier)
        if !field.stringValue.utf8.elementsEqual(value.utf8) {
            field.stringValue = value
            context.coordinator.measuredSize = nil
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let cell = nsView.cell else { return nil }
        // SwiftUI can ask for the same size repeatedly during layout. Keep
        // only this label's last actual measurement; a text or width change
        // measures again, so resizing never reuses the old wrapping height.
        if let measuredSize = context.coordinator.measuredSize, measuredSize.width == width {
            return measuredSize
        }
        let size = cell.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: width, height: .greatestFiniteMagnitude
        ))
        let measuredSize = CGSize(width: width, height: ceil(size.height))
        context.coordinator.measuredSize = measuredSize
        return measuredSize
    }

    private var font: NSFont {
        usesTitleStyle
            ? .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            : .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    }
}
