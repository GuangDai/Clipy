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
import PresentationUI
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Observable state for the scenes (Settings)

    /// The composed application object once `AppComposition.open` has
    /// succeeded; `nil` while opening or after a failure.
    private(set) var composition: AppComposition?

    /// The failure that ended the open attempt, shown in the failure pane.
    private(set) var openFailure: (any Error)?

    /// Guards the open attempt against re-entrancy while its `await`s are
    /// in flight.
    private var isOpening = false

    /// The preview pane state shared by the panel content (SwiftUI) and the
    /// panel window (AppKit) — the single object both sides drive.
    let previewState = PreviewPaneState()

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
        installStatusItem()
        hotKey = GlobalHotKey.summonPanelHotKey { [weak self] in
            self?.togglePanelFromHotKey()
        }
        hotKey?.register()
        openCompositionIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
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
        guard composition == nil, openFailure == nil, !isOpening else { return }
        isOpening = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let opened = try await AppComposition.open()
                // Paste ⇒ close the panel (Maccy's paste-dismiss); the panel
                // never activates the app, so the paste target keeps focus.
                opened.onPasteCompleted = { [weak self] in
                    self?.closePanel()
                }
                composition = opened
            } catch is CancellationError {
                // Stay idle; a later summon retries the open.
            } catch {
                openFailure = error
            }
            isOpening = false
        }
    }

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

    /// Opens the app's Settings window (the selector is not public API,
    /// hence the literal — the standard way to focus the SwiftUI Settings
    /// scene), activating the app first so the window is not stranded
    /// behind the current app (an LSUIElement agent never activates for its
    /// own panel, so a plain sendAction would keep the window behind).
    func openSettingsWindow() {
        NSApp.activate()
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

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
