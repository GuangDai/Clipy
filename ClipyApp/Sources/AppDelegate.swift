/// AppDelegate.swift — the app-lifecycle owner of everything the SwiftUI
/// scenes cannot hold: the menu-bar status item, the floating panel, the
/// global summon hotkey, and the composition open at launch (Maccy's
/// AppDelegate/AppState split, adapted: Maccy keeps an `AppState`
/// observable; Clipy keeps the state ON the delegate so the single
/// `@NSApplicationDelegateAdaptor` serves both the scenes and AppKit).
///
/// Owning spec: docs/01-architecture.md §2 (ClipyApp composition-root row),
/// §6 (window behavior lives on the main actor); the store open is
/// `AppComposition.open` (05 §13) — moved from first-panel-appearance to
/// launch so the capture loop is always live (a clipboard manager that
/// only captures while its panel is open loses history).
///
/// Hosted-test isolation (Maccy's `enable-testing` pattern): under a test
/// host the delegate installs NOTHING — no status item, no hotkey, no
/// production store open; the suites compose their own stacks with private
/// pasteboards and temp stores.
import AppKit
import HistoryCore
import HistoryStorage
import Observation
import PresentationUI
import SwiftUI

#if DEBUG
/// Exact launch envelope for the one running-app XCUI tracer. It is compiled
/// out of Release and accepts only an absolute temp-store path; no alternate
/// History, capture pump, paste path, or panel controller is constructed.
private struct RunningUITestConfiguration {
    let storeURL: URL

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RunningUITestConfiguration? {
        guard environment["CLIPY_RUNNING_UI_TEST"] == "1",
              let path = environment["CLIPY_UI_TEST_STORE_PATH"],
              path.hasPrefix("/")
        else { return nil }
        return RunningUITestConfiguration(
            storeURL: URL(fileURLWithPath: path).standardizedFileURL
        )
    }
}
#endif

/// The only two capture-health episodes that need panel presentation. Both
/// are content-free: replacement exposes a cumulative count, and failure
/// exposes History's typed rejection rather than the clipboard value.
enum ClipyCaptureNotice: Sendable, Equatable {
    case replacedCapture(totalReplaced: Int)
    case failed(ClipyCaptureFailure)
}

@MainActor @Observable
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let accessibilityAnnouncement: AccessibilityAnnouncement

#if DEBUG
    private let runningUITestConfiguration = RunningUITestConfiguration.current()
    private var isRunningUITestSummonPending = true
#endif

    override init() {
        accessibilityAnnouncement = AccessibilityAnnouncement(
            operations: .live
        )
        super.init()
    }

    init(
        accessibilityAnnouncementOperations:
            AccessibilityAnnouncementOperations
    ) {
        accessibilityAnnouncement = AccessibilityAnnouncement(
            operations: accessibilityAnnouncementOperations
        )
        super.init()
    }

    // MARK: - Observable state for the scenes (Settings)

    /// The composed application object once `AppComposition.open` has
    /// succeeded; `nil` while opening or after a failure.
    private(set) var composition: AppComposition?

    /// The failure that ended the open attempt, shown in the failure pane.
    private(set) var openFailure: (any Error)?

    /// Content-free copy failure surfaced over the panel until dismissed or
    /// a later verified copy succeeds.
    private(set) var pasteFailure: ClipyPasteFailure?

    /// Latest content-free snapshot pushed by the production capture owner.
    /// Keeping this on the app shell makes SwiftUI observation direct without
    /// turning the composition root into an observable service object.
    private(set) var captureHealth = ClipyCaptureHealth.inactive

    /// The currently visible capture-health episode. Dismissal clears only
    /// this presentation value; a later replacement or failed-capture count
    /// publishes a new episode even when its typed failure equals the old one.
    private(set) var captureNotice: ClipyCaptureNotice?

    /// Authoritative, content-free pasteboard access posture. It is distinct
    /// from an empty History and controls the access/recovery banner.
    private(set) var captureAccessState: CaptureAccessState = .systemDefault

    /// Neutral launch-at-login status observed by Settings. The controller is
    /// the sole ServiceManagement owner; this snapshot carries no framework
    /// value or error description.
    private(set) var launchAtLoginPresentation = LaunchAtLoginSettings(
        state: .off
    )
    @ObservationIgnored
    private lazy var launchAtLoginController: LaunchAtLoginController = {
        let controller = LaunchAtLoginController(operations: .live)
        launchAtLoginPresentation = controller.presentation
        controller.onPresentationChanged = { [weak self] value in
            self?.launchAtLoginPresentation = value
        }
        return controller
    }()

    /// The one production store-open flight shared by the app shell and the
    /// App Intents dependency provider. Reference identity fences a late
    /// completion from an older cancelled attempt so it cannot clear a later
    /// retry; no wrapping lifecycle counter is needed.
    private final class CompositionOpenAttempt {
        let task: Task<AppComposition, Error>

        init(task: Task<AppComposition, Error>) {
            self.task = task
        }
    }

    private var compositionOpenAttempt: CompositionOpenAttempt?

    /// The preview pane state shared by the panel content (SwiftUI) and the
    /// panel window (AppKit) — the single object both sides drive.
    let previewState = PreviewPaneState()

    /// The one concrete surface shared by the AppKit composition boundary and
    /// its SwiftUI HistoryPanelView. It exists before the composition becomes
    /// externally resolvable, so committed external removal can purge it
    /// synchronously even while the panel is closed.
    private(set) var panelSurfaceState: HistoryPanelSurfaceState?

    /// The side selected from the panel's current screen geometry. The hosted
    /// HistoryPanelView reads this same value to order its columns (Card 9C).
    private(set) var previewPlacement: PreviewPlacement = .trailing

    // MARK: - AppKit-owned surfaces

    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var hotKey: GlobalHotKey?
#if CLIPY_UDS_F0
    /// PLAY-PY-F0 signed discriminator only. The compile flag is absent from
    /// every normal app build, which therefore has no listener behavior.
    private var unixSocketF0Listener: UnixSocketF0Listener?
#endif

    /// The UserDefaults key for the configured summon position (the
    /// Settings picker's `@AppStorage` writes it; the delegate reads it at
    /// summon time so a change applies to the next open). `nonisolated`:
    /// the Settings view's property-wrapper initializer reads it off the
    /// main actor.
    nonisolated static let popupPositionDefaultsKey = "panelPosition"

    /// Hosted-test guard (Maccy's `enable-testing` pattern): the test
    /// runner injects a bundle into the app process; neither the status
    /// bar, the Carbon hotkey, nor the production store may be touched
    /// there. Detected via XCTest linkage or the xcodebuild test
    /// configuration environment.
    static let isRunningTests =
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests || isRunningUITest else { return }

        // App Intents can be invoked immediately after process launch. Install
        // its framework-owned dependency provider before starting any async
        // store work or other app-owned side effect. The provider joins the
        // exact same open flight as the UI shell; it never opens another
        // ModelContainer or creates another History writer (V2-05 §6.5).
        AppIntentDependencyRegistration.registerProduction { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.resolveAppIntentHistoryIngress()
        }

        installStatusItem()
        hotKey = GlobalHotKey.summonPanelHotKey { [weak self] in
            self?.togglePanelFromHotKey()
        }
        hotKey?.register()
        openCompositionIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
        compositionOpenAttempt?.task.cancel()
#if CLIPY_UDS_F0
        unixSocketF0Listener?.stop()
        unixSocketF0Listener = nil
#endif
        composition?.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !Self.isRunningTests || isRunningUITest else { return }
        // System Settings may have changed registration/approval while Clipy
        // was inactive. Re-read the authoritative value; no cached Bool is
        // allowed to survive activation (REVIEW Card 10C).
        launchAtLoginController.refresh()
    }

    // MARK: - Panel lifecycle

    /// The hotkey surface: toggle at the configured position.
    private func togglePanelFromHotKey() {
        if panel?.isPresented == true {
            closePanel()
        } else {
            openPanel(at: configuredPopupPosition())
        }
    }

    /// Status-item clicks always anchor at the status item (Maccy's
    /// `performStatusItemClick`), regardless of the configured mode.
    @objc private func statusItemClicked() {
        if panel?.isPresented == true {
            closePanel()
        } else {
            openPanel(at: .statusItem)
        }
    }

    /// Creates the panel lazily, positions it, and orders it front as key
    /// window. The view state's observation is re-activated per open (the
    /// panel's close deactivates it — browsing state is fresh per summon).
    private func openPanel(at mode: PopupPositionMode) {
        if panel == nil {
            panel = FloatingPanel(
                rootView: PanelRootView(appDelegate: self),
                previewState: previewState,
                onPreviewPlacementChange: { [weak self] placement in
                    self?.previewPlacement = placement
                },
                onClosed: { [weak self] in self?.panelDidClose() }
            )
        }
        composition?.viewState.activate()
        panel?.open(
            at: mode,
            statusItemButtonScreenFrame: statusItemButtonScreenFrame()
        )
        if let composition {
            panelSurfaceState?.beginSession(rows: composition.viewState.rows)
        }
    }

    /// Closes the panel (idempotent; the panel's close fires
    /// `panelDidClose` via its `onPanelClosed` callback).
    func closePanel() {
        panel?.close()
    }

    func dismissPasteFailure() {
        pasteFailure = nil
    }

    func dismissCaptureNotice() {
        captureNotice = nil
    }

    func recoverCaptureAccess() {
        switch captureAccessState.recovery {
        case .resume:
            composition?.setCapturePaused(false)
        case .retry:
            composition?.retryCaptureAccess()
        case nil:
            break
        }
    }

    /// The preview column's visibility changed inside the SwiftUI content;
    /// resize the window to match (single no-animation `setFrame`).
    func previewVisibilityDidChange(_ isOpen: Bool) {
        panel?.setPreviewVisible(isOpen)
    }

    /// Bookkeeping after every panel close: disarm the preview pane and
    /// stop the view-state observation until the next summon.
    private func panelDidClose() {
        panelSurfaceState?.endSession()
        composition?.viewState.deactivate()
    }

    // MARK: - Composition open

    /// Opens the composed store exactly once per non-terminal state (the
    /// MenuBarExtra-era open, moved to launch): while opening, the panel
    /// shows a progress view; on failure, the failure pane; a cancelled
    /// attempt returns to idle so a later summon retries.
    func openCompositionIfNeeded() {
        guard composition == nil,
              openFailure == nil,
              compositionOpenAttempt == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await openOrAwaitComposition()
            } catch is CancellationError {
                // Stay idle; a later summon retries the open.
            } catch {
                // `openOrAwaitComposition` retains the original failure for
                // the panel; App Intents receives only a content-free mapped
                // availability error from its registration boundary.
            }
        }
    }

    /// Returns the one opened app graph, starting it when neither the app
    /// shell nor App Intents has done so. All waiters join the same Task.
    /// A cancelled attempt clears its slot and remains retryable; a genuine
    /// open failure remains terminal for the app shell and keeps its original
    /// diagnostic value in `openFailure`.
    private func openOrAwaitComposition() async throws -> AppComposition {
        if let composition {
            return composition
        }
        if let openFailure {
            throw openFailure
        }

        let attempt: CompositionOpenAttempt
        if let current = compositionOpenAttempt {
            attempt = current
        } else {
#if DEBUG
            let runningUITestConfiguration = self.runningUITestConfiguration
#endif
            let started = Task { @MainActor in
#if DEBUG
                if let configuration = runningUITestConfiguration {
                    return try await AppComposition.openForUITesting(
                        storeURL: configuration.storeURL
                    )
                }
#endif
                return try await AppComposition.open()
            }
            let newAttempt = CompositionOpenAttempt(task: started)
            compositionOpenAttempt = newAttempt
            attempt = newAttempt
        }

        do {
            let opened = try await attempt.task.value
            if composition == nil {
                installComposition(opened)
#if CLIPY_UDS_F0
                startUnixSocketF0ListenerIfRequested()
#endif
#if DEBUG
                if runningUITestConfiguration != nil,
                   isRunningUITestSummonPending {
                    isRunningUITestSummonPending = false
                    hotKey?.fire()
                }
#endif
            }
            if compositionOpenAttempt === attempt {
                compositionOpenAttempt = nil
            }
            return composition ?? opened
        } catch is CancellationError {
            if compositionOpenAttempt === attempt {
                compositionOpenAttempt = nil
                openFailure = nil
            }
            throw CancellationError()
        } catch {
            if compositionOpenAttempt === attempt {
                compositionOpenAttempt = nil
                openFailure = error
            }
            throw error
        }
    }

    private var isRunningUITest: Bool {
#if DEBUG
        runningUITestConfiguration != nil
#else
        false
#endif
    }

    /// App Intents' async dependency provider. The registration boundary
    /// maps every open/unavailable failure to the content-free X.6 transient
    /// vocabulary; this method therefore keeps the app shell's richer error
    /// untouched while returning only the retained app ingress on success.
    private func resolveAppIntentHistoryIngress() async throws -> AppIntentHistoryIngress {
        let opened = try await openOrAwaitComposition()
        guard let ingress = opened.appIntentHistoryIngress else {
            throw ExternalFailure.temporarilyUnavailable(.storeLocked)
        }
        return ingress
    }

    /// Installs the production owner-to-shell callbacks. Capture health stays
    /// a direct owner-to-shell push; there is no timer, toast bus, or generic
    /// health registry between the lane and its only UI consumer.
    private func installComposition(_ opened: AppComposition) {
        let panelSurfaceState = HistoryPanelSurfaceState(
            viewState: opened.viewState,
            previewState: previewState
        )
        opened.installPanelSurface(panelSurfaceState)
        self.panelSurfaceState = panelSurfaceState
        // Paste ⇒ close the panel (Maccy's paste-dismiss); the panel never
        // activates the app, so the paste target keeps focus.
        opened.onPasteCompleted = { [weak self] in
            self?.pasteFailure = nil
            self?.closePanel()
        }
        opened.onPasteFailed = { [weak self] failure in
            self?.pasteFailure = failure
        }
        opened.onHistoryItemRemoved = { [weak self] in
            self?.accessibilityAnnouncement.announceHistoryItemRemoved()
        }
        opened.onCaptureHealthChanged = { [weak self] health in
            self?.receiveCaptureHealth(health)
        }
        opened.onCaptureAccessStateChanged = { [weak self] state in
            self?.captureAccessState = state
        }
        composition = opened
    }

#if CLIPY_UDS_F0
    /// Starts only after the production graph has been installed. The hosted
    /// test helper calls `installComposition` directly and therefore cannot
    /// accidentally publish this runtime-only endpoint.
    private func startUnixSocketF0ListenerIfRequested() {
        guard unixSocketF0Listener == nil,
              let endpointPath = ProcessInfo.processInfo.environment[
                  UnixSocketF0Protocol.endpointEnvironmentKey
              ] else {
            return
        }
        unixSocketF0Listener = try? UnixSocketF0Listener.start(
            endpointPath: endpointPath
        )
    }
#endif

    private func receiveCaptureHealth(_ health: ClipyCaptureHealth) {
        let previous = captureHealth
        // The two episode counts are cumulative for one composition lifetime.
        // A late snapshot from an older admission may change lane occupancy,
        // but it cannot authoritatively recover or replace a newer episode.
        guard health.failedCaptureCount >= previous.failedCaptureCount,
              health.replacedCaptureCount >= previous.replacedCaptureCount
        else { return }
        captureHealth = health

        if health.failedCaptureCount > previous.failedCaptureCount,
           let failure = health.lastFailure {
            captureNotice = .failed(failure)
            accessibilityAnnouncement.announceCaptureFailure(failure)
        } else if health.replacedCaptureCount > previous.replacedCaptureCount {
            captureNotice = .replacedCapture(
                totalReplaced: health.replacedCaptureCount
            )
        } else if health.lastFailure == nil,
                  case .failed? = captureNotice {
            // A later successful capture is authoritative recovery for the
            // failed episode. Replacement notices remain until dismissed.
            captureNotice = nil
        }
    }

#if DEBUG
    /// Hosted tests substitute only the real composition's system boundaries,
    /// then install it through the same callback wiring as production.
    func installCompositionForTesting(_ composition: AppComposition) {
        installComposition(composition)
    }

    /// Hosted Card 15D tests enter through the composition-owned callback
    /// boundary without constructing an AX tree or real assistive client.
    func receiveCaptureHealthForTesting(_ health: ClipyCaptureHealth) {
        receiveCaptureHealth(health)
    }
#endif

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "list.clipboard",
                accessibilityDescription: "Clipy"
            )
            button.action = #selector(statusItemClicked)
            button.target = self
        }
        statusItem = item
    }

    /// The status-item button's frame in screen coordinates (Maccy's
    /// `convert(bounds, to: nil)` + `convertToScreen` pair); nil when the
    /// button/window is unavailable — the geometry then falls back to the
    /// cursor position.
    private func statusItemButtonScreenFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else {
            return nil
        }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: - Settings / position configuration

    // Settings presentation moved to PanelRootView's
    // `@Environment(\.openSettings)` (audit S-5 / SPEC-IMPL-010): the
    // private `showSettingsWindow:` responder selector formerly sent here
    // is not public API, while `OpenSettingsAction` is documented since
    // macOS 14 and the panel's NSHostingView content is a live SwiftUI
    // render tree that carries the app's Settings-scene action.

    /// The configured summon position, read fresh from defaults so a
    /// Settings change applies to the next hotkey press.
    private func configuredPopupPosition() -> PopupPositionMode {
        guard let raw = UserDefaults.standard.string(forKey: Self.popupPositionDefaultsKey) else {
            return .cursor
        }
        return PopupPositionMode(rawValue: raw) ?? .cursor
    }

    /// Immutable neutral state plus narrow intents. Keeping the historical
    /// method name avoids a second composition call site while replacing its
    /// lossy Bool contract.
    func launchAtLoginBinding() -> LaunchAtLoginSettings {
        // First access constructs the live controller and publishes its
        // authoritative status; hosted tests that never open Settings do not
        // touch process-global ServiceManagement state.
        _ = launchAtLoginController
        return LaunchAtLoginSettings(
            state: launchAtLoginPresentation.state,
            operationFailed: launchAtLoginPresentation.operationFailed,
            setEnabled: { [weak self] enabled in
                self?.launchAtLoginController.setEnabled(enabled)
            },
            refresh: { [weak self] in
                self?.launchAtLoginController.refresh()
            },
            openSystemSettings: { [weak self] in
                self?.launchAtLoginController.openSystemSettings()
            }
        )
    }
}
