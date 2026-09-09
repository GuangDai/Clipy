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
/// selection (review Card 9B). Authoritative row removal, revision, or filter
/// exclusion also dismisses the exact target without automatically reopening
/// it for another item or version.
///
/// Pure SwiftUI over HistoryCore DTOs: no AppKit, no SwiftData (01 §6/§8).
import Foundation
import HistoryCore
import SwiftUI

/// The full-panel quick-look layer for one exact item reference. The
/// content background occludes the list and preview column. A separate,
/// lightweight toolbar keeps Close clear of the document; Close, Esc, and
/// Space dismiss through `onDismiss`. The preview fills the current window.
struct HistoryQuickLookOverlay: View {
    private let viewState: HistoryViewState
    private let previewState: PreviewPaneState
    private let item: HistoryItemReference
    private let sourceIcons: SourceIconStore?
    private let onDismiss: () -> Void

    init(
        viewState: HistoryViewState,
        previewState: PreviewPaneState,
        item: HistoryItemReference,
        sourceIcons: SourceIconStore? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.viewState = viewState
        self.previewState = previewState
        self.item = item
        self.sourceIcons = sourceIcons
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(PreviewCopy.text("Quick Look preview"), systemImage: "eye")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .padding(4)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel(PreviewCopy.text("Close"))
                .help(PreviewCopy.text("Close"))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("clipy.panel.quicklook.dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            Divider().opacity(0.5)
            HistoryPreviewView(
                viewState: viewState,
                previewState: previewState,
                item: item,
                sourceIcons: sourceIcons
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.panel.quicklook")
        .accessibilityLabel(PreviewCopy.text("Quick Look preview"))
    }
}
