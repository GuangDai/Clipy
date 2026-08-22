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

    /// The public Settings-scene presentation action (audit S-5 /
    /// SPEC-IMPL-010, replacing `AppDelegate.openSettingsWindow`'s private
    /// `showSettingsWindow:` selector): `OpenSettingsAction` is documented
    /// public API since macOS 14 (Apple:
    /// `EnvironmentValues.openSettings`). The panel's NSHostingView content
    /// is a live SwiftUI render tree of this app — whose `App` declares a
    /// `Settings` scene (ClipyAppMain.swift) — so the environment resolves
    /// the action here.
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let composition = appDelegate.composition {
                HistoryPanelView(
                    viewState: composition.viewState,
                    previewState: appDelegate.previewState,
                    previewPlacement: appDelegate.previewPlacement,
                    onOpenSettings: {
                        // Activate first (the old `openSettingsWindow`
                        // behavior): an LSUIElement agent never activates
                        // on its own, so without this the Settings window
                        // can strand behind the current app.
                        NSApp.activate()
                        openSettings()
                    },
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
        .overlay(alignment: .top) {
            if let pasteFailure = appDelegate.pasteFailure {
                pasteFailureBanner(pasteFailure)
                    .padding(8)
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

    private func pasteFailureBanner(_ failure: ClipyPasteFailure) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(pasteFailureMessage(failure))
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                appDelegate.dismissPasteFailure()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss copy failure")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }

    private func pasteFailureMessage(_ failure: ClipyPasteFailure) -> String {
        switch failure {
        case .busy:
            return "A copy is already in progress. Try again when it finishes."
        case .history(let historyFailure):
            return FailurePresentation.message(for: historyFailure)
        case .write:
            return "The pasteboard refused this copy. Try again."
        }
    }
}
