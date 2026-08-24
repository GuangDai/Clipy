/// HistoryRowView.swift — one rich history row: a 36×36 thumbnail (or an
/// SF Symbol type fallback), the highlighted title/snippet, the trailing
/// metadata column, and the row context menu.
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
/// `HistoryRow` DTO plus the reference-exact thumbnail already cached for
/// `row.item`; mutations are expressed only through the injected callbacks so
/// the row never talks to storage itself (01 §6).
struct HistoryRowView: View {
    private let row: HistoryRow
    private let rendering: HistoryRowRenderingModel
    private let pinnedOrdinal: Int?
    private let thumbnails: ThumbnailStore
    private let onCopy: (HistoryItemReference) -> Void
    private let onPin: (HistoryItemID, PinnedPlacement) -> Void
    private let onUnpin: (HistoryItemID) -> Void
    private let onRemove: (HistoryItemID) -> Void
    private let onShowDetails: (HistoryItemReference) -> Void

    init(
        row: HistoryRow,
        now: Date,
        pinnedOrdinal: Int?,
        thumbnails: ThumbnailStore,
        onCopy: @escaping (HistoryItemReference) -> Void,
        onPin: @escaping (HistoryItemID, PinnedPlacement) -> Void,
        onUnpin: @escaping (HistoryItemID) -> Void,
        onRemove: @escaping (HistoryItemID) -> Void,
        onShowDetails: @escaping (HistoryItemReference) -> Void
    ) {
        self.row = row
        rendering = HistoryRowRenderingModel(row: row, now: now)
        self.pinnedOrdinal = pinnedOrdinal
        self.thumbnails = thumbnails
        self.onCopy = onCopy
        self.onPin = onPin
        self.onUnpin = onUnpin
        self.onRemove = onRemove
        self.onShowDetails = onShowDetails
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                title
                if let search = row.search, let snippet = search.snippet {
                    Text(MatchHighlighting.highlighted(snippet, ranges: search.matchedRanges))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            metadataColumn
        }
        .padding(.vertical, 4)
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

    /// 36×36 leading slot. Prefetch is gated by the cheap UTI heuristic so
    /// text rows never enter the thumbnail pipeline; observable state retains
    /// only a framework-neutral eager raster (01 §6; 04 §9).
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
            } else {
                Image(systemName: Self.typeSymbol(for: row.typeIdentifiers))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .background {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) { pinBadge }
        .task(id: row.item) {
            if ThumbnailStore.likelyThumbnailable(row.typeIdentifiers) {
                thumbnails.prefetch(row.item)
            }
        }
        .accessibilityHidden(true)
    }

    /// pin.fill accent badge plus the 1-based display ordinal —
    /// `HistoryRow.pinnedPosition` is 0-based and the UI adds one itself
    /// (03b §8).
    @ViewBuilder
    private var pinBadge: some View {
        if let ordinal = pinnedOrdinal {
            HStack(spacing: 1) {
                Image(systemName: "pin.fill")
                Text("\(ordinal)")
            }
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background { Capsule().fill(.tint) }
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
        VStack(alignment: .trailing, spacing: 2) {
            Text(rendering.relativeTimeText)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    /// SF Symbol fallback by representation type family; anything not
    /// image/URL/rich-text falls back to the generic clipboard document.
    private static func typeSymbol(for typeIdentifiers: [String]) -> String {
        func matches(_ prefixes: [String]) -> Bool {
            typeIdentifiers.contains { identifier in
                prefixes.contains { identifier.hasPrefix($0) }
            }
        }
        if matches([
            "public.image", "public.png", "public.jpeg",
            "public.tiff", "public.heic", "com.compuserve.gif"
        ]) {
            return "photo"
        }
        if matches(["public.url", "public.file-url"]) {
            return "link"
        }
        if matches(["public.html", "public.rtf", "com.apple.flat-rtfd"]) {
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
