/// HistoryRowView.swift — one rich history row: a density-sized thumbnail
/// (or the retained source-app icon, or an SF Symbol type fallback), the
/// highlighted title/snippet, the trailing metadata column, and the row
/// context menu. Row metrics come from `PanelTheme`'s density mappings; the
/// `comfortable` default is the shipped 36pt-thumbnail, 4pt-padding,
/// two-line-snippet layout exactly.
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

/// A single row of the panel list. Rendering is a pure function of the
/// `HistoryRow` DTO plus the reference-exact thumbnail and bundle-ID-keyed
/// source icon already cached for it; mutations are expressed only through
/// the injected callbacks so the row never talks to storage itself (01 §6).
struct HistoryRowView: View {
    private let row: HistoryRow
    private let rendering: HistoryRowRenderingModel
    private let pinnedOrdinal: Int?
    private let density: HistoryRowDensity
    private let thumbnails: ThumbnailStore
    private let sourceIcons: SourceIconStore?
    private let onCopy: (HistoryItemReference) -> Void
    private let onPin: (HistoryItemID, PinnedPlacement) -> Void
    private let onUnpin: (HistoryItemID) -> Void
    private let onRemove: (HistoryItemID) -> Void
    private let onShowDetails: (HistoryItemReference) -> Void

    init(
        row: HistoryRow,
        now: Date,
        pinnedOrdinal: Int?,
        density: HistoryRowDensity = .comfortable,
        thumbnails: ThumbnailStore,
        sourceIcons: SourceIconStore? = nil,
        onCopy: @escaping (HistoryItemReference) -> Void,
        onPin: @escaping (HistoryItemID, PinnedPlacement) -> Void,
        onUnpin: @escaping (HistoryItemID) -> Void,
        onRemove: @escaping (HistoryItemID) -> Void,
        onShowDetails: @escaping (HistoryItemReference) -> Void
    ) {
        self.row = row
        rendering = HistoryRowRenderingModel(row: row, now: now)
        self.pinnedOrdinal = pinnedOrdinal
        self.density = density
        self.thumbnails = thumbnails
        self.sourceIcons = sourceIcons
        self.onCopy = onCopy
        self.onPin = onPin
        self.onUnpin = onUnpin
        self.onRemove = onRemove
        self.onShowDetails = onShowDetails
    }

    var body: some View {
        HStack(alignment: .center, spacing: PanelTheme.spacingMedium) {
            thumbnail
            VStack(alignment: .leading, spacing: PanelTheme.spacingXXXSmall) {
                title
                if let search = row.search, let snippet = search.snippet {
                    Text(MatchHighlighting.highlighted(snippet, ranges: search.matchedRanges))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(PanelTheme.snippetLineLimit(for: density))
                }
            }
            Spacer(minLength: PanelTheme.spacingSmall)
            metadataColumn
        }
        .padding(.vertical, PanelTheme.rowVerticalPadding(for: density))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onCopy(row.item) }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clipy.history.row.\(row.item.id.description)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onCopy(row.item)
        }
        .accessibilityAction(named: Text(pinAccessibilityActionName)) {
            if row.pinnedPosition == nil {
                onPin(row.item.id, .first)
            } else {
                onUnpin(row.item.id)
            }
        }
        .accessibilityAction(named: Text("Show Details")) {
            onShowDetails(row.item)
        }
        .accessibilityAction(named: Text("Remove")) {
            onRemove(row.item.id)
        }
        .accessibilityHint("Copies this item to the clipboard.")
    }

    // MARK: Leading thumbnail

    /// Density-sized leading slot (36pt comfortable / 28pt compact via
    /// `PanelTheme.thumbnailSize(for:)`). Prefetch is gated by the cheap UTI
    /// heuristic so text rows never enter the thumbnail pipeline; observable
    /// state retains only a framework-neutral eager raster (01 §6; 04 §9).
    /// While no raster is retained, the slot shows the source-app icon when
    /// the surface's icon store has one cached, else the type-family symbol.
    private var thumbnail: some View {
        Group {
            if let raster = thumbnails.raster(for: row.item),
               let image = PreviewRasterDisplay.image(
                   raster,
                   scale: 2,
                   label: Text("Item thumbnail")
               ) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let sourceIcon {
                Image(decorative: sourceIcon, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: Self.typeSymbol(for: row.typeIdentifiers))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(
            width: PanelTheme.thumbnailSize(for: density),
            height: PanelTheme.thumbnailSize(for: density)
        )
        .background {
            RoundedRectangle(cornerRadius: PanelTheme.cornerRadiusMedium)
                .fill(.quaternary)
        }
        .clipShape(RoundedRectangle(cornerRadius: PanelTheme.cornerRadiusMedium))
        .overlay(alignment: .bottomLeading) { pinBadge }
        .task(id: row.item) {
            if ThumbnailStore.likelyThumbnailable(row.typeIdentifiers) {
                thumbnails.prefetch(row.item)
            }
            if let lastSource = row.lastSource {
                // Resolution mutates the store, so it runs here rather than
                // in body evaluation; the row reads `cachedIcon` only.
                sourceIcons?.icon(forBundleID: lastSource)
            }
        }
        .accessibilityHidden(true)
    }

    /// The retained source-app icon for the row's observed bundle identifier,
    /// consulted only while the slot has no thumbnail raster. A pure read:
    /// provider resolution runs in the slot's `.task` above.
    private var sourceIcon: CGImage? {
        guard let lastSource = row.lastSource else { return nil }
        return sourceIcons?.cachedIcon(forBundleID: lastSource)
    }

    /// pin.fill badge plus the 1-based display ordinal —
    /// `HistoryRow.pinnedPosition` is 0-based and the UI adds one itself
    /// (03b §8). `.primary` on thin material keeps the badge legible against
    /// any accent color (white-on-tint failed contrast with light accents);
    /// the badge's size and accessibility label are unchanged.
    @ViewBuilder
    private var pinBadge: some View {
        if let ordinal = pinnedOrdinal {
            HStack(spacing: 1) {
                Image(systemName: "pin.fill")
                Text("\(ordinal)")
            }
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background { Capsule().fill(.thinMaterial) }
            .accessibilityLabel("Pinned at position \(ordinal)")
        }
    }

    // MARK: Title

    /// A title match has `snippet == nil` and UTF-16 ranges relative to the
    /// title; when a snippet is present the ranges belong to that excerpt, so
    /// the title renders unhighlighted (03b §8).
    private var title: some View {
        Text(displayedTitle)
            .font(.headline)
            .lineLimit(1)
    }

    private var displayedTitle: AttributedString {
        guard let search = row.search, search.snippet == nil else {
            return AttributedString(row.title)
        }
        return MatchHighlighting.highlighted(row.title, ranges: search.matchedRanges)
    }

    // MARK: Trailing metadata column

    private var metadataColumn: some View {
        VStack(alignment: .trailing, spacing: PanelTheme.spacingXXXSmall) {
            Text(rendering.relativeTimeText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let source = sourceDisplayName {
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if row.copyCount > 1 {
                Text(copyCountText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(copyAccessibilityLabel)
            }
        }
    }

    /// Plain-`String` rendering of the ×N count: `Text(_:)`'s
    /// `LocalizedStringKey` interpolation has no `UInt64` overload, so the
    /// count is formatted before reaching the view.
    private var copyCountText: String {
        "×\(row.copyCount)"
    }

    /// Accessibility rendering of the same count, precomputed for the same
    /// `UInt64`-interpolation reason (docs/v2/V2-07-ux.md §9 point 1).
    private var copyAccessibilityLabel: String {
        "Copied \(row.copyCount) times"
    }

    /// The compact Actions rotor exposes the state-changing pin operation,
    /// not the context menu's two placement variants. Placement remains an
    /// explicit pointer/keyboard-menu choice while assistive technology gets
    /// one unambiguous Pin or Unpin action (V2-07 §9).
    private var pinAccessibilityActionName: String {
        row.pinnedPosition == nil ? "Pin" : "Unpin"
    }

    /// Last path component of the observed source bundle identifier
    /// (`com.example.DocumentEditor` → `DocumentEditor`).
    private var sourceDisplayName: String? {
        guard let lastSource = row.lastSource else { return nil }
        let parts = lastSource.split(separator: ".")
        return parts.last.map { String($0) }
    }

    /// SF Symbol fallback by representation type family, classified through
    /// the shared `HistoryRowKind` UTI vocabulary so the panel's type filter
    /// always agrees with the displayed family; anything not
    /// image/URL/rich-text falls back to the generic clipboard document.
    private static func typeSymbol(for typeIdentifiers: [String]) -> String {
        if HistoryRowKind.matchesAny(
            typeIdentifiers,
            prefixes: HistoryRowKind.imageTypePrefixes
        ) {
            return "photo"
        }
        if HistoryRowKind.matchesAny(
            typeIdentifiers,
            prefixes: HistoryRowKind.linkTypePrefixes
        ) {
            return "link"
        }
        if HistoryRowKind.matchesAny(
            typeIdentifiers,
            prefixes: HistoryRowKind.richTextTypePrefixes
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
            Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
        }

        if row.pinnedPosition != nil {
            Button {
                onPin(row.item.id, .first)
            } label: {
                Label("Move to Top", systemImage: "arrow.up.to.line")
            }
            Button {
                onPin(row.item.id, .last)
            } label: {
                Label("Move to Bottom", systemImage: "arrow.down.to.line")
            }
            Button {
                onUnpin(row.item.id)
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }
        } else {
            Button {
                onPin(row.item.id, .first)
            } label: {
                Label("Pin to Top", systemImage: "pin")
            }
            Button {
                onPin(row.item.id, .last)
            } label: {
                Label("Pin to Bottom", systemImage: "pin")
            }
        }

        Button {
            onShowDetails(row.item)
        } label: {
            Label("Show Details", systemImage: "info.circle")
        }
        .keyboardShortcut("i", modifiers: .command)

        Divider()

        Button(role: .destructive) {
            onRemove(row.item.id)
        } label: {
            Label("Remove", systemImage: "trash")
        }
        .keyboardShortcut(.delete, modifiers: [])
    }
}

/// Deterministic row rendering at an explicitly supplied instant. The list
/// owns the clock cadence and supplies one shared `now` to all rows; the row
/// owns only formatting, so it never creates a timer or reaches for a global
/// time service (review relative-time refresh leaf; 01 §6).
@MainActor
package struct HistoryRowRenderingModel {
    package let relativeTimeText: String

    package init(
        row: HistoryRow,
        now: Date,
        locale: Locale = .current
    ) {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = locale
        relativeTimeText = formatter.localizedString(
            for: row.lastCopiedAt,
            relativeTo: now
        )
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
