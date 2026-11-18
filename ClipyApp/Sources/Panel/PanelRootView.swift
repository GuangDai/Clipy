/// PanelRootView.swift — the floating panel's root content: the composed
/// history panel once the store is open, the opening progress view before
/// it, and the launch-failure pane after a failed open (the
/// MenuBarExtra-era three-state content, moved into the AppKit panel).
/// Owning spec: docs/architecture.md (composition root), §6
/// (main-actor UI); failure vocabulary docs/architecture.md
import AppKit
import HistoryCore
import SwiftUI

/// The panel's content root. Reads the app delegate's composition state
/// through `@Observable` tracking; the concrete browsing surface is
/// PresentationUI's `HistoryPanelView` with every AppKit callback wired
/// back to the delegate (01 §8: PresentationUI never sees AppKit).
struct PanelRootView: View {
    @State private var readingPositionNoticeDismissed = false
    @State private var measuredTopNotices: TopNoticeMeasurement?
    let appDelegate: AppDelegate
    var motionPresentation: AppMotionPresentation?
    @Environment(\.locale) private var locale

    private struct TopNotices: Equatable {
        let sessionGeneration: Int?
        let locale: Locale
        let showsReadingPosition: Bool
        let captureAccess: CaptureAccessState?
        let pasteFailure: ClipyPasteFailure?
        let captureNotice: ClipyCaptureNotice?

        var isEmpty: Bool {
            !showsReadingPosition && captureAccess == nil && pasteFailure == nil && captureNotice == nil
        }
    }

    private struct TopNoticeMeasurement: Equatable {
        let notices: TopNotices
        let height: CGFloat
    }

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
        let notices = TopNotices(
            sessionGeneration: appDelegate.panelSurfaceState?.sessionGeneration,
            locale: locale,
            showsReadingPosition: showsReadingPositionNotice,
            captureAccess: captureAccessNeedsAttention ? appDelegate.captureAccessState : nil,
            pasteFailure: appDelegate.pasteFailure,
            captureNotice: appDelegate.captureNotice
        )
        let topNoticeHeight: CGFloat? = notices.isEmpty ? 0 : measuredTopNotices.flatMap {
            $0.notices == notices ? $0.height : nil
        }
        VStack(spacing: 0) {
            if !notices.isEmpty {
                VStack(spacing: 8) {
                    if notices.showsReadingPosition { readingPositionNotice }
                    if let access = notices.captureAccess {
                        captureAccessBanner(access)
                    }
                    if let pasteFailure = notices.pasteFailure {
                        pasteFailureBanner(pasteFailure)
                    }
                    if let captureNotice = notices.captureNotice {
                        captureNoticeBanner(captureNotice)
                    }
                }
                .padding(8)
                // Measure only the notices' natural width-dependent height;
                // fitting the window must not compress and remeasure them.
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        let height = geometry.size.height
                        let measurement = TopNoticeMeasurement(
                            notices: notices, height: height.isFinite ? max(0, height) : 0
                        )
                        NativePanelBackground().onChange(of: measurement, initial: true) { _, measured in
                            measuredTopNotices = measured
                        }
                    }
                }
            }
            animatedPanelContent(topNoticeHeight: topNoticeHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.workflowExecutionQueue, appDelegate.composition?.workflowRunner.executionQueue)
        .environment(\.searchHistoryStore, appDelegate.searchHistoryStore)
        .environment(\.openSearchSavingSettings, {
            NSApp.activate()
            openSettings()
        })
        .environment(\.historyBrowsingPreferences, appDelegate.historyBrowsingPreferences)
        // The notice stack and animated browsing content share one static
        // window clip. Notice rendering stays independent of the animation.
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onChange(of: appDelegate.composition?.viewState.readingPositionLoss) { _, loss in
            readingPositionNoticeDismissed = false
            if loss == .saved {
                appDelegate.historyBrowsingPreferences.clearReadingPosition(for: .panel)
            }
        }
        .onAppear {
            appDelegate.installSettingsOpenOperation {
                NSApp.activate()
                openSettings()
            }
        }
    }

    @ViewBuilder
    private func animatedPanelContent(topNoticeHeight: CGFloat?) -> some View {
        let content = panelContent(topNoticeHeight: topNoticeHeight).background { NativePanelBackground() }
        if let motionPresentation {
            content.modifier(AppMotionSurface(presentation: motionPresentation))
        } else {
            content
        }
    }

    @ViewBuilder
    private func panelContent(topNoticeHeight: CGFloat?) -> some View {
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
                            SourceIconProviderFactory.makeProvider(),
                        topNoticeHeight: topNoticeHeight,
                        // The analytic content-fit demand flows back to the
                        // AppKit owner, which coalesces and fits the
                        // window's height (`FloatingPanel.fitToContent`).
                        onContentFitChange: { input in
                            appDelegate.panelContentFitDidChange(input)
                        }
                    )
                }
            } else if let openFailure = appDelegate.openFailure {
                failurePane(for: openFailure)
            } else {
                ProgressView(AppRecoveryCopy.text("Opening Clipy…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var showsReadingPositionNotice: Bool {
        appDelegate.composition?.viewState.didLoseReadingPosition == true && !readingPositionNoticeDismissed
    }

    private var readingPositionNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Label(HistoryBrowsingCopy.readingPositionUnavailable(appDelegate.composition?.viewState.readingPositionLoss ?? .live),
                systemImage: "info.circle")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                readingPositionNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PanelActionsCopy.text("Dismiss"))
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .accessibilityIdentifier("clipy.history.reading-position.notice")
    }

    private var captureAccessNeedsAttention: Bool {
        appDelegate.composition != nil
            && appDelegate.captureAccessState != .allowed
            && !showsCaptureAccessEmptyState(appDelegate.composition)
    }

    private func showsCaptureAccessEmptyState(
        _ composition: AppComposition?
    ) -> Bool {
        guard let viewState = composition?.viewState else { return false }
        return appDelegate.captureAccessState != .allowed
            && viewState.hasAuthoritativeFirstPage
            && viewState.failure == nil
            && viewState.rows.isEmpty
            && !viewState.isSearchActive
            && !viewState.hasActiveFilters
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
            Text(AppRecoveryCopy.failureCategory(for: error))
                .font(.headline)
                .accessibilityIdentifier(
                    "clipy.store.open.failure.category"
                )
            Text(AppRecoveryCopy.failureMessage(for: error))
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
        // window rather than pin the default 360×420 frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.store.open.failure")
    }

    private func pasteFailureBanner(_ failure: ClipyPasteFailure) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text(Self.pasteFailureMessage(failure))
                .font(.callout)
                .lineLimit(2)
                .accessibilityIdentifier("clipy.paste.failure.message")
            Spacer(minLength: 8)
            Button {
                appDelegate.dismissPasteFailure()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppRecoveryCopy.text("Dismiss copy failure"))
            .accessibilityIdentifier("clipy.paste.failure.dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.paste.failure.banner")
    }

    static func pasteFailureMessage(
        _ failure: ClipyPasteFailure, bundle: Bundle = AppLocalization.bundle
    ) -> String {
        switch failure {
        case .busy:
            return AppRecoveryCopy.text("A copy is already in progress. Try again when it finishes.", bundle: bundle)
        case .history(let historyFailure):
            return FailurePresentation.message(for: historyFailure)
        case .write(.ownershipChanged):
            return AppRecoveryCopy.text("The clipboard changed. Copy the history item again to replace it.", bundle: bundle)
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
                appDelegate.dismissCaptureNotice(notice)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppCaptureCopy.text("Dismiss capture warning"))
            .accessibilityIdentifier("clipy.capture.notice.dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
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
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
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
        // user-resizable window rather than pin the default 360×420 frame.
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
