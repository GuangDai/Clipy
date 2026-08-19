/// ClipyAppMain.swift — the @main entry point: the LSUIElement menu-bar
/// agent shape (set in project.yml — no Dock icon), the MenuBarExtra
/// browsing surface, and the Settings scene.
/// Owning spec: docs/01-architecture.md §2 (composition-root row) and §6
/// (main actor owns views and window behavior); paste wiring lives in
/// AppComposition (01 §5.6); roadmap docs/roadmap/06-clipyapp.md (step 9b).
import AppKit
import HistoryCore
import PresentationUI
import ServiceManagement
import SwiftUI

/// Clipy itself — the composition root's user-facing shell.
///
/// The app is one `MenuBarExtra` in `.window` style hosting
/// `HistoryPanelView` (the main and only browsing surface) plus a
/// `Settings` scene. The store opens asynchronously at first panel
/// appearance: while opening, the panel shows a progress view; on failure,
/// an error pane with the typed `HistoryFailure` message and a Quit
/// button; once open, the composed `AppComposition` supplies the view
/// state to both scenes. Scene content lives on the main actor (01 §6).
@main
struct ClipyAppMain: App {
    /// The composed application object once `AppComposition.open` has
    /// succeeded; `nil` while opening or after a failure.
    @State private var composition: AppComposition?

    /// The failure that ended the open attempt, shown in the error pane.
    @State private var openFailure: (any Error)?

    /// Guards the open attempt against re-entrancy while its `await`s are
    /// in flight (`.task` may fire again before the first open resolves).
    @State private var isOpening = false

    var body: some Scene {
        MenuBarExtra("Clipy", systemImage: "list.clipboard") {
            Group {
                panelContent
            }
            .task { await openCompositionIfNeeded() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            settingsContent
        }
    }

    // MARK: Panel content

    /// The menu-bar panel: the history list once composed, the error pane
    /// after a failed open, and the opening progress view otherwise.
    @ViewBuilder
    private var panelContent: some View {
        if let composition {
            HistoryPanelView(
                viewState: composition.viewState,
                onOpenSettings: { openSettingsWindow() },
                onQuit: { NSApp.terminate(nil) }
            )
        } else if let openFailure {
            failurePane(for: openFailure)
        } else {
            ProgressView("Opening Clipy…")
                .frame(minWidth: 320, minHeight: 120)
        }
    }

    /// Opens the composed store exactly once per non-terminal state; a
    /// cancelled attempt (the panel disappeared mid-open) returns to the
    /// idle state so the next appearance retries (05 §13 has no partial
    /// open to resume).
    @MainActor
    private func openCompositionIfNeeded() async {
        guard composition == nil, openFailure == nil, !isOpening else {
            return
        }
        isOpening = true
        defer { isOpening = false }
        do {
            composition = try await AppComposition.open()
        } catch is CancellationError {
            // Stay idle; the next `.task` appearance retries the open.
        } catch {
            openFailure = error
        }
    }

    /// The launch failure pane (01 §13-style fail-loud, no silent repair):
    /// the typed message rendered by `FailurePresentation` (03b §10) plus a
    /// Quit button — a menu-bar agent with no usable store has nothing else
    /// to offer.
    @MainActor
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
        .frame(minWidth: 320, minHeight: 160)
    }

    /// Maps the open failure to its user-facing message. `HistoryFailure`
    /// — including directory-creation failures surfaced as
    /// `.persistence(.openStore)` by the composition — renders through
    /// PresentationUI's shared vocabulary so the pane and the in-panel
    /// banner never disagree (03b §10).
    @MainActor
    private func failureMessage(for error: any Error) -> String {
        if let historyFailure = error as? HistoryFailure {
            return FailurePresentation.message(for: historyFailure)
        }
        if error is ClipyCompositionError {
            return "Clipy's history store is already open in this app. Quit Clipy and try again."
        }
        return "Clipy couldn't open its history store."
    }

    // MARK: Settings content

    /// The Settings scene: the real settings once the composition exists,
    /// `EmptyView` until then (the store must open before any view state
    /// exists to drive retention edits).
    @ViewBuilder
    private var settingsContent: some View {
        if let composition {
            ClipySettingsView(
                viewState: composition.viewState,
                launchAtLogin: launchAtLoginBinding()
            )
        } else {
            EmptyView()
        }
    }

    /// The Launch-at-Login toggle backing, wired here — the sole legal home
    /// for ServiceManagement (PresentationUI never imports it; roadmap 05).
    /// Reads the authoritative `SMAppService.mainApp.status` and applies
    /// register/unregister; a failed registration (for example denied by
    /// the user) intentionally re-reads the authoritative status rather
    /// than surfacing an error sheet v1 does not have.
    @MainActor
    private func launchAtLoginBinding() -> Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    // Best effort: the binding's next get re-reads the
                    // authoritative status, snapping the toggle back.
                }
            }
        )
    }

    /// Opens the app's Settings window on the panel's "Settings…" command.
    /// The selector is not exposed as public API, hence the literal — the
    /// standard way to focus the SwiftUI Settings scene.
    @MainActor
    private func openSettingsWindow() {
        _ = NSApp.sendAction(
            Selector(("showSettingsWindow:")), to: nil, from: nil
        )
    }
}
