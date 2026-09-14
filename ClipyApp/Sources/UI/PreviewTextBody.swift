import AppKit
import SwiftUI

/// Selectable preview text shared by the floating pane and Quick Look.
struct PreviewTextBody: View {
    let segments: [Substring]
    let groups: [Range<Int>]
    var maximumHeight: CGFloat?
    @State private var contentHeight: CGFloat?
    #if DEBUG
    var onSegmentMaterialized: ((Int) -> Void)?
    var onGroupMaterialized: ((Int) -> Void)?
    #endif

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups, id: \.lowerBound) { group in
                    textGroup(group)
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
                // of its lazy height must not rebuild the visible groups.
                guard height != currentHeight else { return }
                contentHeight = height
            }
        }
        .frame(height: maximumHeight.map { min(contentHeight ?? $0, max(0, $0)) })
    }

    private func textGroup(_ range: Range<Int>) -> some View {
        #if DEBUG
        return PreviewTextSegmentGroup(text: segments[range],
            onMaterialized: onSegmentMaterialized, onGroupMaterialized: onGroupMaterialized).equatable()
        #else
        return PreviewTextSegmentGroup(text: segments[range]).equatable()
        #endif
    }
}

/// The renderer groups only short single-line segments. One lazy leaf owns
/// at most eight independent native fields; it never joins their strings and
/// recreates an oversized combining sequence (01 §6; V2-11 text previews).
private struct PreviewTextSegmentGroup: View, Equatable {
    let text: ArraySlice<Substring>
    #if DEBUG
    var onMaterialized: ((Int) -> Void)?
    var onGroupMaterialized: ((Int) -> Void)?
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text.indices == rhs.text.indices
            && lhs.text.elementsEqual(rhs.text) { $0.utf8.elementsEqual($1.utf8) }
    }

    var body: some View {
        #if DEBUG
        onGroupMaterialized?(text.startIndex)
        for index in text.indices { onMaterialized?(index) }
        #endif
        return PreviewTextGroupLabel(segments: text)
    }
}

private struct PreviewTextGroupLabel: NSViewRepresentable {
    let segments: ArraySlice<Substring>
    @Environment(\.layoutDirection) private var layoutDirection

    private var alignment: NSTextAlignment {
        layoutDirection == .rightToLeft ? .right : .left
    }

    func makeNSView(context: Context) -> PreviewTextGroupView {
        let view = PreviewTextGroupView(frame: .zero)
        view.autoresizesSubviews = false
        view.configure(segments: segments, alignment: alignment)
        return view
    }

    func updateNSView(_ view: PreviewTextGroupView, context: Context) {
        view.configure(segments: segments, alignment: alignment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PreviewTextGroupView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return nsView.measuredSize(width: width)
    }
}

/// A small vertical stack with real NSTextFields and no nested Auto Layout
/// or SwiftUI bridge per field. Resizing, direction changes and value updates
/// reuse surviving fields so their native responder/selection identity stays.
private final class PreviewTextGroupView: NSView {
    private var fields: [NSTextField] = []
    private var segmentIndices = 0..<0
    private var measuredWidth: CGFloat?
    private var heights: [CGFloat] = []

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = frame.width != newSize.width
        super.setFrameSize(newSize)
        if widthChanged { needsLayout = true }
    }

    func configure(segments: ArraySlice<Substring>, alignment: NSTextAlignment) {
        guard fields.count != segments.count || segmentIndices != segments.indices
                || !zip(fields, segments).allSatisfy({ pair in
                    pair.0.alignment == alignment && pair.0.stringValue.utf8.elementsEqual(pair.1.utf8)
                }) else { return }

        if fields.count > segments.count {
            for field in fields.dropFirst(segments.count) { field.removeFromSuperview() }
            fields.removeLast(fields.count - segments.count)
        }
        let font = NSFont.preferredFont(forTextStyle: .body)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = []
        for (offset, text) in segments.enumerated() {
            let field: NSTextField
            let isNew = offset == fields.count
            if isNew {
                field = NSTextField(wrappingLabelWithString: "")
                field.font = font
                field.textColor = .labelColor
                field.isSelectable = true
                field.lineBreakMode = .byWordWrapping
                field.lineBreakStrategy = []
                field.maximumNumberOfLines = 0
                fields.append(field)
                addSubview(field)
            } else { field = fields[offset] }

            let index = segments.startIndex + offset
            field.setAccessibilityIdentifier(index == 0
                ? "clipy.preview.text" : "clipy.preview.text.segment.\(index)")
            if isNew || field.alignment != alignment || !field.stringValue.utf8.elementsEqual(text.utf8) {
                field.alignment = alignment
                field.attributedStringValue = NSAttributedString(string: String(text), attributes: [
                    .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
                ])
            }
        }
        segmentIndices = segments.indices
        measuredWidth = nil
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    func measuredSize(width: CGFloat) -> CGSize {
        if measuredWidth != width {
            heights = fields.map { field in
                ceil(field.cell?.cellSize(forBounds: NSRect(
                    x: 0, y: 0, width: width, height: .greatestFiniteMagnitude
                )).height ?? 0)
            }
            measuredWidth = width
        }
        return CGSize(width: width, height: heights.reduce(0, +))
    }

    override func layout() {
        super.layout()
        guard bounds.width.isFinite, bounds.width > 0 else { return }
        _ = measuredSize(width: bounds.width)
        var top: CGFloat = 0
        for (field, height) in zip(fields, heights) {
            field.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
            top += height
        }
    }
}
