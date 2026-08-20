/// PanelRootView.swift — the floating panel's root content: the composed
/// history panel once the store is open, the opening progress view before
/// it, and the launch-failure pane after a failed open (the
/// MenuBarExtra-era three-state content, moved into the AppKit panel).
/// Owning spec: docs/01-architecture.md §2 (composition root), §6
/// (main-actor UI); failure vocabulary docs/03b-instruction-set.md §10.
import AppKit
import HistoryCore
import PresentationUI
import SwiftUI

/// The panel's content root. Reads the app delegate's composition state
/// through `@Observable` tracking; the concrete browsing surface is
/// PresentationUI's `HistoryPanelView` with every AppKit callback wired
/// back to the delegate (01 §8: PresentationUI never sees AppKit).
struct PanelRootView: View {
    let appDelegate: AppDelegate

    var body: some View {
        Group {
            if let composition = appDelegate.composition {
                HistoryPanelView(
                    viewState: composition.viewState,
                    previewState: appDelegate.previewState,
                    onOpenSettings: { appDelegate.openSettingsWindow() },
                    onQuit: { NSApp.terminate(nil) },
                    onRequestClose: { appDelegate.closePanel() },
                    onPreviewVisibilityChange: { isOpen in
                        appDelegate.previewVisibilityDidChange(isOpen)
                    }
                )
            } else if let openFailure = appDelegate.openFailure {
                failurePane(for: openFailure)
            } else {
                ProgressView("Opening Clipy…")
                    .frame(
                        width: PanelGeometry.contentWidth,
                        height: PanelGeometry.height
                    )
            }
        }
        // The panel window is transparent; the content carries the
        // material so the rounded corners (FloatingPanel's content layer)
        // show material, not the desktop behind it.
        .background(.regularMaterial)
    }

    /// The launch failure pane (fail-loud, no silent repair): the typed
    /// message rendered by `FailurePresentation` (03b §10) plus a Quit
    /// button — a menu-bar agent with no usable store has nothing else to
    /// offer.
    @ViewBuilder
    private func failurePane(for error: any Error) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(failureMessage(for: error))
                .multilineTextAlignment(.center)
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(20)
        .frame(
            width: PanelGeometry.contentWidth,
            height: PanelGeometry.height
        )
    }

    /// Maps the open failure to its user-facing message (the
    /// MenuBarExtra-era mapping, unchanged): `HistoryFailure` renders
    /// through PresentationUI's shared vocabulary so the pane and the
    /// in-panel banner never disagree (03b §10).
    private func failureMessage(for error: any Error) -> String {
        if let historyFailure = error as? HistoryFailure {
            return FailurePresentation.message(for: historyFailure)
        }
        if error is ClipyCompositionError {
            return "Clipy's history store is already open in this app. Quit Clipy and try again."
        }
        return "Clipy couldn't open its history store."
    }
}
