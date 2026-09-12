import AppKit
import SwiftUI

/// Selectable preview text shared by the floating pane and Quick Look.
struct PreviewTextBody: View {
    let segments: [Substring]
    var maximumHeight: CGFloat?
    @State private var contentHeight: CGFloat?
    #if DEBUG
    var onSegmentMaterialized: ((Int) -> Void)?
    #endif

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(segments.indices, id: \.self) { index in
                    textSegment(index)
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
                // of its lazy height must not rebuild the same visible Texts.
                guard height != currentHeight else { return }
                contentHeight = height
            }
        }
        // Start with a real viewport so lazy layout can materialize its first
        // screen. Short content then fits its measured height; long content
        // never requests a full-document intrinsic-size measurement.
        .frame(height: maximumHeight.map { min(contentHeight ?? $0, max(0, $0)) })
    }

    private func textSegment(_ index: Int) -> some View {
        #if DEBUG
        return PreviewTextSegment(text: segments[index], index: index,
                                  onMaterialized: onSegmentMaterialized).equatable()
        #else
        return PreviewTextSegment(text: segments[index], index: index).equatable()
        #endif
    }
}

/// Lazy layout may request a row more than once while refining the viewport.
/// Keep substring materialization and selectable label construction inside a
/// stable leaf, so unchanged rows can reuse that work (V2-11 text previews).
private struct PreviewTextSegment: View, Equatable {
    let text: Substring
    let index: Int
    #if DEBUG
    var onMaterialized: ((Int) -> Void)?
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }

    var body: some View {
        #if DEBUG
        onMaterialized?(index)
        #endif
        return PreviewTextLabel(value: String(text), identifier: index == 0
                ? "clipy.preview.text" : "clipy.preview.text.segment.\(index)")
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A viewport containing many short combining-only segments should not pay
/// SwiftUI's selectable Text construction cost for every row. Each native
/// label retains the complete segment and supports selection across its wraps.
private struct PreviewTextLabel: NSViewRepresentable {
    let value: String
    let identifier: String
    @Environment(\.layoutDirection) private var layoutDirection

    private var alignment: NSTextAlignment {
        layoutDirection == .rightToLeft ? .right : .left
    }

    @MainActor
    final class Coordinator {
        var measuredSize: CGSize?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .preferredFont(forTextStyle: .body)
        field.textColor = .labelColor
        field.isSelectable = true
        field.lineBreakMode = .byWordWrapping
        field.lineBreakStrategy = []
        field.maximumNumberOfLines = 0
        field.setAccessibilityIdentifier(identifier)
        setText(on: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        guard !field.stringValue.utf8.elementsEqual(value.utf8)
                || field.alignment != alignment else { return }
        setText(on: field)
        context.coordinator.measuredSize = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let cell = nsView.cell else { return nil }
        if let measuredSize = context.coordinator.measuredSize, measuredSize.width == width {
            return measuredSize
        }
        // Cache only this row's last measured size. A width or text change
        // remeasures its full content; no estimated or clipped document height.
        let size = cell.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: width, height: .greatestFiniteMagnitude
        ))
        let measuredSize = CGSize(width: width, height: ceil(size.height))
        context.coordinator.measuredSize = measuredSize
        return measuredSize
    }

    private func setText(on field: NSTextField) {
        field.alignment = alignment
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = []
        field.attributedStringValue = NSAttributedString(string: value, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
    }
}
