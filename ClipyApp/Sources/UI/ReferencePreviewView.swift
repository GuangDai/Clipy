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

/// The disclosure's complete selectable spelling, also exercised directly by
/// the hosted native layout test. It owns no expansion state or destination I/O.
struct FullReferencePreviewContent: View {
    let reference: PreviewReference

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let path = reference.filePath {
                FullReferenceText(
                    value: path, identifier: "clipy.preview.reference.full.path"
                )
            }
            FullReferenceText(
                value: reference.address, identifier: "clipy.preview.reference.full.address"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }
}

/// References contain long uninterrupted components. Character wrapping avoids
/// expensive word-boundary layout while keeping the entire original value in
/// one native selectable label, including selections across visual line breaks.
private struct FullReferenceText: NSViewRepresentable {
    let value: String
    let identifier: String

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byCharWrapping
        field.lineBreakStrategy = []
        field.maximumNumberOfLines = 0
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if !field.stringValue.utf8.elementsEqual(value.utf8) {
            field.stringValue = value
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let cell = nsView.cell else { return nil }
        let size = cell.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: width, height: .greatestFiniteMagnitude
        ))
        return CGSize(width: width, height: ceil(size.height))
    }
}
