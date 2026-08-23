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
import PresentationUI
import ServiceManagement
import SwiftUI

/// The only two capture-health episodes that need panel presentation. Both
/// are content-free: replacement exposes a cumulative count, and failure
/// exposes History's typed rejection rather than the clipboard value.
enum ClipyCaptureNotice: Sendable, Equatable {
    case replacedCapture(totalReplaced: Int)
    case failed(ClipyCaptureFailure)
}

@MainActor @Observable
final class AppDelegate: NSObject, NSApplicationDelegate {

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

    /// The side selected from the panel's current screen geometry. The hosted
    /// HistoryPanelView reads this same value to order its columns (Card 9C).
    private(set) var previewPlacement: PreviewPlacement = .trailing

    // MARK: - AppKit-owned surfaces

    private var statusItem: NSStatusItem?
    private var panel: FloatingPanel?
    private var hotKey: GlobalHotKey?

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
        guard !Self.isRunningTests else { return }

        // App Intents can be invoked immediately after process launch. Install
        // its framework-owned dependency provider before starting any async
        // store work or other app-owned side effect. The provider joins the
        // exact same open flight as the UI shell; it never opens another
        // ModelContainer or creates another History writer (V2-05 §6.5).
        AppIntentDependencyRegistration.registerProduction { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.resolveAppIntentsHistoryFacade()
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
        composition?.stop()
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
        panel?.open(
            at: mode,
            statusItemButtonScreenFrame: statusItemButtonScreenFrame()
        )
        composition?.viewState.activate()
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

    /// The preview column's visibility changed inside the SwiftUI content;
    /// resize the window to match (single no-animation `setFrame`).
    func previewVisibilityDidChange(_ isOpen: Bool) {
        panel?.setPreviewVisible(isOpen)
    }

    /// Bookkeeping after every panel close: disarm the preview pane and
    /// stop the view-state observation until the next summon.
    private func panelDidClose() {
        previewState.panelClosed()
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
            let started = Task { @MainActor in
                try await AppComposition.open()
            }
            let newAttempt = CompositionOpenAttempt(task: started)
            compositionOpenAttempt = newAttempt
            attempt = newAttempt
        }

        do {
            let opened = try await attempt.task.value
            if composition == nil {
                installComposition(opened)
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

    /// App Intents' async dependency provider. The registration boundary
    /// maps every open/unavailable failure to the content-free X.6 transient
    /// vocabulary; this method therefore keeps the app shell's richer error
    /// untouched while returning only the retained facade on success.
    private func resolveAppIntentsHistoryFacade() async throws -> ExternalHistoryFacade {
        let opened = try await openOrAwaitComposition()
        guard let facade = opened.appIntentsHistoryFacade else {
            throw ExternalFailure.temporarilyUnavailable(.storeLocked)
        }
        return facade
    }

    /// Installs the three one-way production callbacks. Capture health stays
    /// a direct owner-to-shell push; there is no timer, toast bus, or generic
    /// health registry between the lane and its only UI consumer.
    private func installComposition(_ opened: AppComposition) {
        // Paste ⇒ close the panel (Maccy's paste-dismiss); the panel never
        // activates the app, so the paste target keeps focus.
        opened.onPasteCompleted = { [weak self] in
            self?.pasteFailure = nil
            self?.closePanel()
        }
        opened.onPasteFailed = { [weak self] failure in
            self?.pasteFailure = failure
        }
        opened.onCaptureHealthChanged = { [weak self] health in
            self?.receiveCaptureHealth(health)
        }
        composition = opened
    }

    private func receiveCaptureHealth(_ health: ClipyCaptureHealth) {
        let previous = captureHealth
        captureHealth = health

        if health.failedCaptureCount > previous.failedCaptureCount,
           let failure = health.lastFailure {
            captureNotice = .failed(failure)
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

    /// The Launch-at-Login toggle backing, wired here — the sole legal home
    /// for ServiceManagement (PresentationUI never imports it; roadmap 05).
    /// Reads the authoritative `SMAppService.mainApp.status` and applies
    /// register/unregister; a failed registration (for example denied by
    /// the user) intentionally re-reads the authoritative status rather
    /// than surfacing an error sheet v1 does not have.
    func launchAtLoginBinding() -> Binding<Bool> {
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
}
