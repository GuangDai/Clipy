/// HistoryRowView.swift — content-first history rows. Titles and search
/// excerpts share the available column width. Copy provenance lives in the
/// expanded preview; a small accessory identifies multi-source items. Native List selection owns selection
/// contrast, while pointer hover supplies a quieter secondary highlight.
/// Owning spec: docs/01-architecture.md §5.2 (gesture actions), §5.7
/// (thumbnail is requested by exact `HistoryItemReference`);
/// docs/03b-instruction-set.md §8 (row fields, search presentation, 1-based
/// pin ordinal display) and §12 (paste hand-off);
/// docs/04-coherence.md §9 (thumbnail single-flight, reference-exact cache);
/// accessibility per docs/v2/V2-07-ux.md §9.
import CoreGraphics
import Foundation
import HistoryCore
import SwiftUI

/// The row's accessibility activation vocabulary (docs/v2/V2-07-ux.md §9):
/// the default activation and the named Actions-rotor entries the combined
/// row element exposes. Default activation is the paste hand-off
/// (docs/01-architecture.md §5.6 — the UI hands a reference to the
/// composition root and never touches the pasteboard itself), while the
/// named actions mirror the mutating caller examples of
/// docs/03b-instruction-set.md §12 (`.placePinned`/`.unpin`/`.remove`)
/// plus the details push. One enum so the four `accessibilityAction`
/// modifiers, the single dispatch method beneath them, and the direct
/// route/intent tests all share one routing table.
enum HistoryRowAccessibilityAction {
    /// Default activation: copy to clipboard through `onCopy` (01 §5.6).
    case paste
    /// The rotor's one state-changing pin operation — `Pin` while the row
    /// is unpinned, `Unpin` while pinned — never the context menu's two
    /// placement variants (V2-07 §9).
    case togglePin
    /// The details push, the same intent as ⌘I (03b §12; V2-07 §9).
    case showDetails
    /// The destructive removal, the same intent as ⌫ (03b §12; V2-07 §9).
    case remove
}

/// A single row of the panel list. Rendering is a pure function of the
/// `HistoryRow` DTO plus the reference-exact thumbnail and bundle-ID-keyed
/// source icon already cached for it; mutations are expressed only through
/// the injected callbacks so the row never talks to storage itself (01 §6).
struct HistoryRowView: View {
    private let row: HistoryRow
    private let now: Date
    private let pinnedOrdinal: Int?
    private let density: HistoryRowDensity
    private let snippetLineCount: HistorySnippetLineCount
    private let fontSize: HistoryRowFontSize
    private let isSelected: Bool
    private let thumbnails: ThumbnailStore
    private let dragSource: HistoryListDraggingView?
    private let onCopy: (HistoryItemReference) -> Void
    private let onPin: (HistoryItemID, PinnedPlacement) -> Void
    private let onUnpin: (HistoryItemID) -> Void
    private let onRemove: (HistoryItemID) -> Void
    private let onShowDetails: (HistoryItemReference) -> Void

    @State private var isHovered = false
    @State private var dragRegion = HistoryRowDragRegionView()

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    init(
        row: HistoryRow,
        now: Date,
        pinnedOrdinal: Int?,
        density: HistoryRowDensity = .compact,
        snippetLineCount: HistorySnippetLineCount = .automatic,
        fontSize: HistoryRowFontSize = .medium,
        isSelected: Bool = false,
        thumbnails: ThumbnailStore,
        dragSource: HistoryListDraggingView? = nil,
        onCopy: @escaping (HistoryItemReference) -> Void,
        onPin: @escaping (HistoryItemID, PinnedPlacement) -> Void,
        onUnpin: @escaping (HistoryItemID) -> Void,
        onRemove: @escaping (HistoryItemID) -> Void,
        onShowDetails: @escaping (HistoryItemReference) -> Void
    ) {
        self.row = row
        self.now = now
        self.pinnedOrdinal = pinnedOrdinal
        self.density = density
        self.snippetLineCount = snippetLineCount
        self.fontSize = fontSize
        self.isSelected = isSelected
        self.thumbnails = thumbnails
        self.dragSource = dragSource
        self.onCopy = onCopy
        self.onPin = onPin
        self.onUnpin = onUnpin
        self.onRemove = onRemove
        self.onShowDetails = onShowDetails
    }

    var body: some View {
        HStack(alignment: .center, spacing: PanelTheme.spacingSmall) {
            thumbnail
            VStack(alignment: .leading, spacing: PanelTheme.spacingXXSmall) {
                HStack(alignment: .firstTextBaseline, spacing: PanelTheme.spacingXSmall) {
                    title
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if row.sourceCount > 1 {
                        Image(systemName: "square.on.square")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(PreviewCopy.text("Multiple Applications"))
                            .accessibilityLabel(PreviewCopy.text("Multiple Applications"))
                    }
                    pinBadge
                }
                if let search = row.search, let snippet = search.snippet {
                    Text(MatchHighlighting.highlighted(snippet, ranges: search.matchedRanges))
                        .font(PanelTheme.snippetFont(for: fontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(snippetLineCount.baseLineLimit(density: density))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, PanelTheme.rowVerticalPadding(for: density))
        .padding(.horizontal, PanelTheme.spacingXSmall)
        // Like Maccy's ListItemView, the row's dimensions depend only on
        // content kind/typography, never on the asynchronous thumbnail.
        .frame(height: PanelContentFit.rowHeight(
            .init(row: row, snippetLineLimit: snippetLineCount.baseLineLimit(density: density)),
            density: density, fontSize: fontSize
        ) - 2 * PanelContentFit.listRowVerticalInset)
        .background {
            RoundedRectangle(cornerRadius: PanelTheme.cornerRadiusSmall)
                .fill(isHovered && !isSelected ? Color.primary.opacity(0.045) : .clear)
        }
        .background {
            if dragSource != nil { HistoryRowDragRegion(view: dragRegion) }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            // Use the same hit-tested row region as the visible hover state.
            // A transparent background sibling is not the row's event source.
            dragSource?.hover(row.item, region: dragRegion, isInside: inside)
        }
        .onChange(of: row.item) { old, new in
            dragSource?.retire(old)
            dragSource?.refresh(new, region: dragRegion)
        }
        .onDisappear { dragSource?.retire(row.item) }
        .onTapGesture(count: 2) { onCopy(row.item) }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clipy.history.row.\(row.item.id.description)")
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(copyAccessibilityLabel)
        .accessibilityAction {
            performAccessibilityAction(.paste)
        }
        .accessibilityAction(named: Text(pinAccessibilityActionName)) {
            performAccessibilityAction(.togglePin)
        }
        .accessibilityAction(named: Text(PanelActionsCopy.text("Show Details", bundle: copyBundle))) {
            performAccessibilityAction(.showDetails)
        }
        .accessibilityAction(named: Text(PanelActionsCopy.text("Remove", bundle: copyBundle))) {
            performAccessibilityAction(.remove)
        }
        .accessibilityHint(PanelActionsCopy.text("Copies this item to the clipboard.", bundle: copyBundle))
    }

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }

    // MARK: Accessibility action dispatch (V2-07 §9)

    /// The single routing table behind the row's accessibility activations:
    /// default activation is the paste hand-off (01 §5.6; 03b §12), and the
    /// named rotor actions carry the same intents the list's selection
    /// shortcuts already route through `HistoryViewState` (⏎ copy, ⌘P pin
    /// toggle, ⌫ remove, ⌘I details). The four `accessibilityAction`
    /// modifiers above are thin shells over this method so assistive
    /// activation and the direct tests share one path; the context menu,
    /// double-click, and the menu's `.last` placement variants keep their
    /// own call sites (zero behavior change).
    func performAccessibilityAction(
        _ action: HistoryRowAccessibilityAction
    ) {
        switch action {
        case .paste:
            onCopy(row.item)
        case .togglePin:
            if row.pinnedPosition == nil {
                onPin(row.item.id, .first)
            } else {
                onUnpin(row.item.id)
            }
        case .showDetails:
            onShowDetails(row.item)
        case .remove:
            onRemove(row.item.id)
        }
    }

    // MARK: Leading thumbnail

    /// Density-sized leading slot: 16pt compact / 24pt comfortable for text
    /// and type rows (`PanelTheme.thumbnailSize(for:)`), a generous 44/56pt
    /// content height for image rows
    /// (`PanelTheme.imageThumbnailHeight(for:)`). The slot height is fixed
    /// per row kind, so a late async decode never relayouts the row: until a
    /// raster is retained, an image row's slot shows the type-family symbol
    /// scaled to the larger slot. Prefetch is gated by the cheap UTI
    /// heuristic so text rows never enter the thumbnail pipeline; observable
    /// state retains only a framework-neutral eager raster (01 §6; 04 §9).
    private var thumbnail: some View {
        Group {
            if isImageRow {
                imageThumbnail
            } else {
                standardThumbnail
            }
        }
        .onAppear {
            thumbnails.setDisplayed(row.item, true)
        }
        .onDisappear {
            thumbnails.setDisplayed(row.item, false)
        }
        .onChange(of: row.item) { old, new in
            thumbnails.setDisplayed(old, false)
            thumbnails.setDisplayed(new, true)
        }
        .onChange(of: thumbnails.isPrefetchSuspended) { _, suspended in
            if !suspended, ThumbnailStore.likelyThumbnailable(row.typeIdentifiers) {
                thumbnails.prefetch(row.item)
            }
        }
        .onChange(of: thumbnails.isSurfaceActive) { _, active in
            if active, ThumbnailStore.likelyThumbnailable(row.typeIdentifiers) {
                thumbnails.prefetch(row.item)
            }
        }
        .task(id: row.item) {
            guard !Task.isCancelled else { return }
            if ThumbnailStore.likelyThumbnailable(row.typeIdentifiers) {
                thumbnails.prefetch(row.item)
            }
        }
        .accessibilityHidden(true)
    }

    /// True when the row's effective identifiers classify as the image
    /// family — the same `HistoryRowKind` vocabulary the header filter and
    /// the fallback symbol share, so the slot choice, the symbol, and the
    /// type filter always agree.
    private var isImageRow: Bool {
        HistoryRowKind.classify(
            effectiveTypeIdentifiers: row.typeIdentifiers
        ) == .image
    }

    /// The retained eager raster as a SwiftUI image, or nil while the fetch
    /// is pending, unavailable, or undecodable (a pure read — never fetches).
    private var decodedThumbnail: Image? {
        guard let raster = thumbnails.raster(for: row.item) else { return nil }
        return PreviewRasterDisplay.image(
            raster,
            scale: 2,
            label: Text(PanelActionsCopy.text("Item thumbnail", bundle: copyBundle))
        )
    }

    /// Image rows use a stable aspect-fit slot. A panorama must not consume
    /// the entire title, and a decoded thumbnail must not shift its start.
    /// Rounded
    /// continuous corners plus a hairline separator-toned stroke keep white
    /// images readable on the material background.
    @ViewBuilder
    private var imageThumbnail: some View {
        let height = PanelTheme.imageThumbnailHeight(for: density)
        if let image = decodedThumbnail {
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: height * 1.5, height: height)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: PanelTheme.cornerRadiusMedium,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: PanelTheme.cornerRadiusMedium,
                        style: .continuous
                    )
                    .strokeBorder(thumbnailHairline, lineWidth: 0.5)
                }
        } else {
            // The placeholder is the same fixed-height slot with the
            // type-family symbol scaled up, so the row never shifts when
            // the async decode lands. The .quaternary backing lives only
            // behind this symbol fallback.
            Image(systemName: Self.typeSymbol(for: row.typeIdentifiers))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: height * 1.5, height: height)
                .background {
                    RoundedRectangle(
                        cornerRadius: PanelTheme.cornerRadiusMedium,
                        style: .continuous
                    )
                    .fill(.quaternary)
                }
        }
    }

    /// Small unboxed type symbols stay subordinate to the title.
    @ViewBuilder
    private var standardThumbnail: some View {
        Group {
            if let image = decodedThumbnail {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: Self.typeSymbol(for: row.typeIdentifiers))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(
            width: PanelTheme.thumbnailSize(for: density),
            height: PanelTheme.thumbnailSize(for: density)
        )
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.cornerRadiusMedium))
    }

    /// Hairline separator tone for the loaded image stroke. SwiftUI exposes
    /// no separator-color token and this view stays AppKit-free, so the
    /// primary-tinted 12% hairline stands in: it reads on the material in
    /// both light and dark appearances exactly where a white image would
    /// otherwise dissolve into the background.
    private var thumbnailHairline: Color {
        Color.primary.opacity(0.12)
    }

    /// Keep the pin position beside the title, outside the decorative icon,
    /// so its localized position remains part of the combined AX row.
    @ViewBuilder
    private var pinBadge: some View {
        if let ordinal = pinnedOrdinal {
            HStack(spacing: PanelTheme.spacingXXXSmall) {
                Image(systemName: "pin.fill")
                    .imageScale(.small)
                Text(LocalizedCountPresentation.number(ordinal, locale: locale))
                    .monospacedDigit()
            }
            .font(PanelTheme.metadataFont(for: fontSize))
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityLabel(PanelActionsCopy.pinnedPosition(ordinal, bundle: copyBundle, locale: locale))
        }
    }

    // MARK: Title

    /// A title match has `snippet == nil` and UTF-16 ranges relative to the
    /// title; when a snippet is present the ranges belong to that excerpt, so
    /// the title renders unhighlighted (03b §8).
    private var title: some View {
        Text(displayedTitle)
            .font(PanelTheme.titleFont(for: fontSize))
            .fontWeight(.regular)
            .lineLimit(row.search?.snippet == nil ? snippetLineCount.baseLineLimit(density: density) : 1)
            .multilineTextAlignment(.leading)
    }

    private var displayedTitle: AttributedString {
        guard let search = row.search, search.snippet == nil else {
            return AttributedString(row.title)
        }
        return MatchHighlighting.highlighted(row.title, ranges: search.matchedRanges)
    }

    /// The same count with translated plural-aware VoiceOver copy (§9/§10).
    private var copyAccessibilityLabel: String {
        HistoryRowCopy.copiedCount(row.copyCount, bundle: copyBundle, locale: locale)
    }

    /// The compact Actions rotor exposes the state-changing pin operation,
    /// not the context menu's two placement variants. Placement remains an
    /// explicit pointer/keyboard-menu choice while assistive technology gets
    /// one unambiguous Pin or Unpin action (V2-07 §9).
    private var pinAccessibilityActionName: String {
        row.pinnedPosition == nil ? PanelActionsCopy.text("Pin", bundle: copyBundle) : PanelActionsCopy.text("Unpin", bundle: copyBundle)
    }

    /// SF Symbol fallback by representation type family, classified through
    /// the shared `HistoryRowKind` UTI vocabulary so the panel's type filter
    /// always agrees with the displayed family; anything not
    /// image/URL/rich-text falls back to the generic clipboard document.
    static func typeSymbol(for typeIdentifiers: [String]) -> String {
        if HistoryRowKind.matchesAny(
            typeIdentifiers,
            types: HistoryRowKind.imageTypes
        ) {
            return "photo"
        }
        if HistoryRowKind.matchesAny(
            typeIdentifiers,
            types: HistoryRowKind.linkTypes
        ) {
            return "link"
        }
        if HistoryRowKind.matchesAny(
            typeIdentifiers,
            types: HistoryRowKind.richTextTypes
        ) {
            return "doc.text"
        }
        return "doc.on.clipboard"
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            onCopy(row.item)
        } label: {
            Label(PanelActionsCopy.text("Copy to Clipboard", bundle: copyBundle), systemImage: "doc.on.clipboard")
        }

        if row.pinnedPosition != nil {
            Button {
                onPin(row.item.id, .first)
            } label: {
                Label(PanelActionsCopy.text("Move to Top", bundle: copyBundle), systemImage: "arrow.up.to.line")
            }
            Button {
                onPin(row.item.id, .last)
            } label: {
                Label(PanelActionsCopy.text("Move to Bottom", bundle: copyBundle), systemImage: "arrow.down.to.line")
            }
            Button {
                onUnpin(row.item.id)
            } label: {
                Label(PanelActionsCopy.text("Unpin", bundle: copyBundle), systemImage: "pin.slash")
            }
        } else {
            Button {
                onPin(row.item.id, .first)
            } label: {
                Label(PanelActionsCopy.text("Pin to Top", bundle: copyBundle), systemImage: "pin")
            }
            Button {
                onPin(row.item.id, .last)
            } label: {
                Label(PanelActionsCopy.text("Pin to Bottom", bundle: copyBundle), systemImage: "pin")
            }
        }

        Button {
            onShowDetails(row.item)
        } label: {
            Label(PanelActionsCopy.text("Show Details", bundle: copyBundle), systemImage: "info.circle")
        }
        .keyboardShortcut("i", modifiers: .command)

        Divider()

        Button(role: .destructive) {
            onRemove(row.item.id)
        } label: {
            Label(PanelActionsCopy.text("Remove", bundle: copyBundle), systemImage: "trash")
        }
        .keyboardShortcut(.delete, modifiers: [])
    }
}

/// Deterministic row rendering at an explicitly supplied instant. The list
/// owns the clock cadence and supplies one shared `now` to all rows; the row
/// owns only formatting, so it never creates a timer or reaches for a global
/// time service (review relative-time refresh leaf; 01 §6).
/// Time stays relative at every width; a full localized date/time is
/// available in the tooltip and VoiceOver. Both use the supplied locale and
/// zone, and no metadata format changes when the user resizes the panel.
@MainActor
struct HistoryRowRenderingModel {
    let relativeTimeText: String
    let sourceDisplayName: String?
    private let lastCopiedAt: Date
    private let absoluteLocale: Locale
    private let absoluteTimeZone: TimeZone

    init(
        row: HistoryRow,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = locale
        relativeTimeText = formatter.localizedString(
            for: row.lastCopiedAt,
            relativeTo: now
        )
        sourceDisplayName = row.lastSource?.split(separator: ".").last.map(String.init)
        lastCopiedAt = row.lastCopiedAt
        absoluteLocale = locale
        absoluteTimeZone = timeZone
    }

    /// The item's complete local date and time for its tooltip and AX label.
    var absoluteDateTimeText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        formatter.locale = absoluteLocale
        formatter.timeZone = absoluteTimeZone
        return formatter.string(from: lastCopiedAt)
    }

}

#Preview {
    let reference = HistoryItemReference(
        id: HistoryItemID(rawValue: UUID()),
        contentVersion: ContentVersion(rawValue: 1)
    )
    let row = HistoryRow(
        item: reference,
        title: "Quarterly report — final numbers",
        typeIdentifiers: ["public.utf8-plain-text"],
        lastCopiedAt: Date().addingTimeInterval(-420),
        copyCount: 3,
        lastSource: "com.example.DocumentEditor",
        pinnedPosition: 0,
        search: nil
    )
    return HistoryRowView(
        row: row,
        now: Date(),
        pinnedOrdinal: 1,
        thumbnails: ThumbnailStore(history: PreviewClipboardHistory.populated),
        onCopy: { _ in },
        onPin: { _, _ in },
        onUnpin: { _ in },
        onRemove: { _ in },
        onShowDetails: { _ in }
    )
    .padding()
    .frame(width: 380)
}
