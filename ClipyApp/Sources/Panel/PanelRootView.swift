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
            if let composition = appDelegate.composition,
               let surfaceState = appDelegate.panelSurfaceState {
                if showsCaptureAccessEmptyState(composition) {
                    captureAccessEmptyState(appDelegate.captureAccessState)
                } else {
                    HistoryPanelView(
                        viewState: composition.viewState,
                        previewState: appDelegate.previewState,
                        surfaceState: surfaceState,
                        previewPlacement: appDelegate.previewPlacement,
                        onPauseCapture: pauseCaptureAction,
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
                        },
                        appearance: appDelegate.panelAppearance,
                        keepPanelOpenIsActive: appDelegate.isPanelKeepOpenActive,
                        onToggleKeepPanelOpen: {
                            appDelegate.togglePanelKeepOpen()
                        },
                        // The row-icon loader is built at this AppKit
                        // boundary (PresentationUI never sees AppKit,
                        // 01 §8); the view owns the per-surface store it
                        // builds from this public provider.
                        sourceIconProvider:
                            SourceIconProviderFactory.makeProvider()
                    )
                }
            } else if let openFailure = appDelegate.openFailure {
                failurePane(for: openFailure)
            } else {
                ProgressView(AppRecoveryCopy.text("Opening Clipy…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if appDelegate.pasteFailure != nil
                || appDelegate.captureNotice != nil
                || captureAccessNeedsAttention {
                VStack(spacing: 8) {
                    if captureAccessNeedsAttention {
                        captureAccessBanner(appDelegate.captureAccessState)
                    }
                    if let pasteFailure = appDelegate.pasteFailure {
                        pasteFailureBanner(pasteFailure)
                    }
                    if let captureNotice = appDelegate.captureNotice {
                        captureNoticeBanner(captureNotice)
                    }
                }
                .padding(8)
            }
        }
        // The panel window is transparent; the content carries the
        // material so the rounded corners (FloatingPanel's content layer)
        // show material, not the desktop behind it.
        .background(.regularMaterial)
        .onAppear {
            // Republish the documented public OpenSettingsAction to the
            // delegate so the pure-AppKit status-item menu can open the
            // same Settings scene through the same action. Idempotent:
            // every appearance installs an equivalent fresh capture.
            appDelegate.installSettingsOpenOperation {
                NSApp.activate()
                openSettings()
            }
        }
    }

    private var captureAccessNeedsAttention: Bool {
        appDelegate.composition != nil
            && appDelegate.captureAccessState != .allowed
            && !showsCaptureAccessEmptyState(appDelegate.composition)
    }

    private func showsCaptureAccessEmptyState(
        _ composition: AppComposition?
    ) -> Bool {
        guard let composition else { return false }
        return appDelegate.captureAccessState != .allowed
            && composition.viewState.rows.isEmpty
            && !composition.viewState.isLoadingFirstPage
            && !composition.viewState.isSearchActive
    }

    private var pauseCaptureAction: (() -> Void)? {
        guard appDelegate.captureAccessState == .allowed else { return nil }
        return { appDelegate.pauseCapture() }
    }

    /// DATA-14 launch recovery stays non-destructive while open-error
    /// observability is incomplete: show the stable public failure category,
    /// Retry the same locator, Reveal its directory, or Quit. There is no
    /// automatic retry, quarantine, empty-store fallback, or raw error text.
    @ViewBuilder
    private func failurePane(for error: any Error) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(Self.failureCategory(for: error))
                .font(.headline)
                .accessibilityIdentifier(
                    "clipy.store.open.failure.category"
                )
            Text(Self.failureMessage(for: error))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "clipy.store.open.failure.message"
                )
            HStack(spacing: 8) {
                Button(AppRecoveryCopy.text("Retry")) {
                    appDelegate.retryCompositionOpen()
                }
                .accessibilityIdentifier(
                    "clipy.store.open.failure.retry"
                )
                Button(AppRecoveryCopy.text("Reveal Store Location")) {
                    appDelegate.revealStoreLocation()
                }
                .accessibilityIdentifier(
                    "clipy.store.open.failure.reveal"
                )
                Button(AppRecoveryCopy.text("Quit")) {
                    NSApp.terminate(nil)
                }
                .accessibilityIdentifier(
                    "clipy.store.open.failure.quit"
                )
            }
        }
        .padding(20)
        // Fill the hosting panel: the pane must track the user-resizable
        // window rather than pin the default 400×560 frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.store.open.failure")
    }

    /// A stable, content-free diagnostic category derived only from Clipy's
    /// public typed failure. `.openStore` deliberately stays generic because
    /// SwiftData construction does not yet distinguish permission, ENOSPC,
    /// corruption, future schema, and other I/O failures reliably.
    static func failureCategory(for error: any Error, bundle: Bundle = .main) -> String {
        guard let historyFailure = error as? HistoryFailure else {
            return error is ClipyCompositionError
                ? AppRecoveryCopy.text("History Store Already Open", bundle: bundle)
                : AppRecoveryCopy.text("History Store Open Failed", bundle: bundle)
        }
        guard case .persistence(let persistenceFailure) = historyFailure else {
            return AppRecoveryCopy.text("History Store Open Failed", bundle: bundle)
        }
        switch persistenceFailure {
        case .openStore:
            return AppRecoveryCopy.text("History Store Open Failed", bundle: bundle)
        case .storeAlreadyOpen:
            // DATA-7's cross-process lease denial is distinguishable from a
            // flat open failure and names the other live instance.
            return AppRecoveryCopy.text("History Store Already Open", bundle: bundle)
        case .corruptStoredValue:
            return AppRecoveryCopy.text("Stored History Unreadable", bundle: bundle)
        case .invariantViolation:
            return AppRecoveryCopy.text("History Consistency Check Failed", bundle: bundle)
        case .transaction:
            return AppRecoveryCopy.text("History Startup Transaction Failed", bundle: bundle)
        }
    }

    /// Maps the open failure to its user-facing message. `HistoryFailure`
    /// renders through PresentationUI's shared vocabulary so the pane and the
    /// in-panel banner never disagree (03b §10).
    static func failureMessage(for error: any Error, bundle: Bundle = .main) -> String {
        if let historyFailure = error as? HistoryFailure {
            // DATA-7: a live owner in ANOTHER process holds the StoreRoot
            // lease — the finding's "in use by another instance" wording,
            // not the generic storage error.
            if case .persistence(.storeAlreadyOpen) = historyFailure {
                return AppRecoveryCopy.text("Clipy's history store is already open in another instance. Quit that instance and try again.", bundle: bundle)
            }
            return FailurePresentation.message(for: historyFailure)
        }
        if error is ClipyCompositionError {
            return AppRecoveryCopy.text("Clipy's history store is already open in this app. Quit Clipy and try again.", bundle: bundle)
        }
        return AppRecoveryCopy.text("Clipy couldn't open its history store.", bundle: bundle)
    }

    private func pasteFailureBanner(_ failure: ClipyPasteFailure) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(Self.pasteFailureMessage(failure))
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                appDelegate.dismissPasteFailure()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppRecoveryCopy.text("Dismiss copy failure"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }

    static func pasteFailureMessage(
        _ failure: ClipyPasteFailure, bundle: Bundle = .main
    ) -> String {
        switch failure {
        case .busy:
            return AppRecoveryCopy.text("A copy is already in progress. Try again when it finishes.", bundle: bundle)
        case .history(let historyFailure):
            return FailurePresentation.message(for: historyFailure)
        case .write:
            return AppRecoveryCopy.text("The pasteboard refused this copy. Try again.", bundle: bundle)
        }
    }

    /// Card 6 health never renders clipboard bytes, declared types, source
    /// applications, or query text. No Retry button is offered because the
    /// bounded owner intentionally does not retain a rejected/replaced value
    /// after its episode; the message states the safe new-copy action instead.
    private func captureNoticeBanner(_ notice: ClipyCaptureNotice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(CaptureNoticePresentation.message(for: notice))
                .font(.callout)
                .accessibilityIdentifier("clipy.capture.notice.message")
            Spacer(minLength: 8)
            Button {
                appDelegate.dismissCaptureNotice()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppCaptureCopy.text("Dismiss capture warning"))
            .accessibilityIdentifier("clipy.capture.notice.dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.capture.notice.banner")
    }

    /// Access state is intentionally separate from capture failure state: a
    /// denied/default pasteboard must never look like empty History. Messages
    /// contain no clipboard value, type, source application, or framework
    /// error. Runtime prompt/System Settings behavior remains a signed gate.
    private func captureAccessBanner(_ state: CaptureAccessState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(AppCaptureCopy.accessMessage(state))
                .font(.callout)
                .accessibilityIdentifier("clipy.capture.access.message")
            Spacer(minLength: 8)
            if let recovery = state.recovery {
                captureAccessRecoveryButton(recovery)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.capture.access.banner")
    }

    /// When no retained row exists, access failure owns the whole content
    /// state. The ordinary `No Clipboard History` view is not rendered, so
    /// assistive clients cannot conflate "nothing copied" with "not allowed
    /// to monitor". Retained rows continue through HistoryPanelView above.
    private func captureAccessEmptyState(
        _ state: CaptureAccessState
    ) -> some View {
        ZStack {
            VStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(AppCaptureCopy.text("Clipboard Monitoring Unavailable"))
                    .font(.headline)
                    .accessibilityIdentifier("clipy.capture.access.empty")
                Text(AppCaptureCopy.accessMessage(state))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("clipy.capture.access.message")
                if let recovery = state.recovery {
                    captureAccessRecoveryButton(recovery)
                }
            }
            .accessibilityElement(children: .contain)
        }
        .padding(20)
        // Fill the hosting panel: the empty state must track the
        // user-resizable window rather than pin the default 400×560 frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.panel.root")
    }

    private func captureAccessRecoveryButton(
        _ recovery: CaptureAccessRecovery
    ) -> some View {
        Button(AppCaptureCopy.recoveryTitle(recovery)) {
            appDelegate.recoverCaptureAccess()
        }
        .accessibilityLabel(AppCaptureCopy.recoveryLabel(recovery))
        .accessibilityIdentifier("clipy.capture.access.recovery")
    }

}
