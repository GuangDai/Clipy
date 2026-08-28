/// HistoryQuickLookOverlay.swift — the panel's Space-triggered quick-look
/// overlay: the selected item rendered large above the whole browsing
/// surface, replicating Maccy's Quick Look panel shortcut as a panel-local
/// SwiftUI layer instead of a separate window (01 §8 keeps every AppKit
/// window in ClipyApp).
///
/// The overlay embeds `HistoryPreviewView` with a pinned exact reference, so
/// the fenced loader, the `clipy.preview.*` identifiers, the typed failure
/// taxonomy, and the ⌘R retry behave exactly as they do in the side pane
/// (SPEC-IMPL-007 / PREVIEW-FENCE-1). Dismissal is panel-local state:
/// `HistoryPanelSurfaceState.quickLookReference` is cleared by the close
/// button, Space/Esc, and the same purge/session transitions that retire the
/// selection (review Card 9B), so overlay content can never outlive its
/// authoritative row.
///
/// Pure SwiftUI over HistoryCore DTOs: no AppKit, no SwiftData (01 §6/§8).
import Foundation
import HistoryCore
import SwiftUI

/// The full-panel quick-look layer for one exact item reference. The
/// regular-material background occludes the list and preview column so
/// clipboard content does not show around the overlay; the top-trailing
/// Close button, Esc, and Space all dismiss through `onDismiss`.
struct HistoryQuickLookOverlay: View {
    private let viewState: HistoryViewState
    private let previewState: PreviewPaneState
    private let item: HistoryItemReference
    private let onDismiss: () -> Void

    init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        item: HistoryItemReference,
        onDismiss: @escaping () -> Void
    ) {
        self.viewState = viewState
        self.previewState = previewState
        self.item = item
        self.onDismiss = onDismiss
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HistoryPreviewView(
                viewState: viewState,
                previewState: previewState,
                item: item
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            // Esc dismisses the overlay; the panel's list-root Esc shortcut
            // checks the overlay first, so both paths agree.
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("clipy.panel.quicklook.dismiss")
            .padding(PanelTheme.spacingSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.panel.quicklook")
        .accessibilityLabel("Quick Look preview")
    }
}
