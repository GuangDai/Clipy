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
import PasteboardAdapter
import PresentationUI
import SwiftUI

#if DEBUG
/// Exact launch envelope for the running-app XCUI journeys. It is compiled
/// out of Release and accepts only an absolute temp-store path, exact privacy
/// facts, an exact short-Pause switch, bounded loader/editor journeys, and an
/// optional content-free StoreRoot-sibling Reveal marker; no alternate
/// store/writer, capture pump, paste path, panel controller, or timer owner is
/// constructed.
struct RunningUITestConfiguration {
    private static let storeRevealMarkerName =
        "clipy-store-reveal.marker"

    enum EditorJourney: Equatable {
        case none
        case staleThenReloadFailureOnce
    }

    let storeURL: URL
    let initialCaptureAccessBehavior: PasteboardAccessBehavior
    let currentCaptureAccessBehavior: PasteboardAccessBehavior
    let capturePauseDuration: Duration
    let editorJourney: EditorJourney
    let storeRevealMarkerURL: URL?

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RunningUITestConfiguration? {
        guard environment["CLIPY_RUNNING_UI_TEST"] == "1",
              let path = environment["CLIPY_UI_TEST_STORE_PATH"],
              path.hasPrefix("/")
        else { return nil }
        let storeURL = URL(fileURLWithPath: path).standardizedFileURL

        let initialCaptureAccessBehavior: PasteboardAccessBehavior
        let currentCaptureAccessBehavior: PasteboardAccessBehavior
        switch environment["CLIPY_UI_TEST_CAPTURE_ACCESS"] {
        case nil, "allowed":
            initialCaptureAccessBehavior = .allowed
            currentCaptureAccessBehavior = .allowed
        case "system-default":
            initialCaptureAccessBehavior = .systemDefault
            currentCaptureAccessBehavior = .systemDefault
        case "system-default-then-allowed":
            initialCaptureAccessBehavior = .systemDefault
            currentCaptureAccessBehavior = .allowed
        case "ask":
            initialCaptureAccessBehavior = .ask
            currentCaptureAccessBehavior = .ask
        case "ask-then-allowed":
            initialCaptureAccessBehavior = .ask
            currentCaptureAccessBehavior = .allowed
        case "denied":
            initialCaptureAccessBehavior = .denied
            currentCaptureAccessBehavior = .denied
        case "denied-then-allowed":
            initialCaptureAccessBehavior = .denied
            currentCaptureAccessBehavior = .allowed
        case "read-failure":
            initialCaptureAccessBehavior = .unavailable
            currentCaptureAccessBehavior = .unavailable
        case "read-failure-then-allowed":
            initialCaptureAccessBehavior = .unavailable
            currentCaptureAccessBehavior = .allowed
        default:
            return nil
        }

        let capturePauseDuration: Duration
        switch environment["CLIPY_UI_TEST_SHORT_PAUSE"] {
        case nil:
            capturePauseDuration = CapturePausePolicy.standardDuration
        case "1":
            capturePauseDuration = CapturePausePolicy.runningUITestDuration
        default:
            return nil
        }
        switch environment["CLIPY_UI_TEST_PREVIEW_FAILURE"] {
        case nil, "transient-details-once":
            break
        default:
            return nil
        }
        let editorJourney: EditorJourney
        switch environment["CLIPY_UI_TEST_EDITOR_JOURNEY"] {
        case nil:
            editorJourney = .none
        case "stale-reload-failure-once":
            editorJourney = .staleThenReloadFailureOnce
        default:
            return nil
        }
        let storeRevealMarkerURL: URL?
        if let markerPath = environment[
            "CLIPY_UI_TEST_STORE_REVEAL_MARKER_PATH"
        ] {
            guard markerPath.hasPrefix("/") else { return nil }
            let candidate = URL(fileURLWithPath: markerPath)
                .standardizedFileURL
            // The marker is the exact fixed-name sibling of the configured
            // StoreRoot. It cannot select another absolute file or hide a
            // second spelling behind `..` in the DEBUG launch envelope.
            let expected = storeURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(Self.storeRevealMarkerName)
            guard candidate.lastPathComponent == Self.storeRevealMarkerName,
                  candidate.path == markerPath,
                  candidate == expected
            else { return nil }
            storeRevealMarkerURL = candidate
        } else {
            storeRevealMarkerURL = nil
        }
        return RunningUITestConfiguration(
            storeURL: storeURL,
            initialCaptureAccessBehavior: initialCaptureAccessBehavior,
            currentCaptureAccessBehavior: currentCaptureAccessBehavior,
            capturePauseDuration: capturePauseDuration,
            editorJourney: editorJourney,
            storeRevealMarkerURL: storeRevealMarkerURL
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
    private let summonShortcutDefaults: UserDefaults
    private let summonShortcutRegistrationFactory:
        SummonShortcutController.RegistrationFactory?
    /// Exact persistent locator this app process attempts to open. Production
    /// uses `AppComposition.defaultStoreURL`; hosted recovery tests inject a
    /// disposable URL so Retry exercises the real composition/store path.
    private let storeURL: URL
    /// The AppKit boundary for DATA-14's non-destructive Reveal action. It is
    /// injected only so hosted tests can assert the exact directory without
    /// opening Finder in the test account.
    private let revealStoreLocationOperation: @MainActor (URL) -> Void

#if DEBUG
    private let runningUITestConfiguration = RunningUITestConfiguration.current()
    private var isRunningUITestSummonPending = true
#endif

    override init() {
        accessibilityAnnouncement = AccessibilityAnnouncement(
            operations: .live
        )
        summonShortcutDefaults = .standard
        summonShortcutRegistrationFactory = nil
        storeURL = AppComposition.defaultStoreURL
        revealStoreLocationOperation = { directory in
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
        super.init()
    }

    init(
        accessibilityAnnouncementOperations:
            AccessibilityAnnouncementOperations,
        summonShortcutDefaults: UserDefaults = .standard,
        summonShortcutRegistrationFactory:
            SummonShortcutController.RegistrationFactory? = nil,
        storeURL: URL = AppComposition.defaultStoreURL,
        revealStoreLocationOperation:
            @escaping @MainActor (URL) -> Void = { directory in
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
    ) {
        accessibilityAnnouncement = AccessibilityAnnouncement(
            operations: accessibilityAnnouncementOperations
        )
        self.summonShortcutDefaults = summonShortcutDefaults
        self.summonShortcutRegistrationFactory =
            summonShortcutRegistrationFactory
        self.storeURL = storeURL
        self.revealStoreLocationOperation = revealStoreLocationOperation
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

    /// Neutral Card 14B status observed by General Settings. The one concrete
    /// controller below remains the sole owner of Carbon registration and the
    /// persisted chord.
    private(set) var summonShortcutPresentation = SummonShortcutSettings(
        status: .stopped
    )
    @ObservationIgnored
    private lazy var summonShortcutController = SummonShortcutController(
        defaults: summonShortcutDefaults,
        action: { [weak self] in self?.togglePanelFromHotKey() },
        registrationFactory: summonShortcutRegistrationFactory
    )

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
#if DEBUG
    /// Set only after the production updater assigns the requested symbol to
    /// the real status-bar button. Hosted evidence can therefore distinguish
    /// an applied image change from merely recomputing state in the test.
    private var appliedStatusItemSymbolNameForTesting: String?
#endif
    private var panel: FloatingPanel?
    /// AppDelegate owns the only NSWorkspace lifecycle registrations. Tokens
    /// are retained only to remove those exact registrations at termination;
    /// no generic notification router or second lifecycle object is created.
    @ObservationIgnored
    private var workspaceLifecycleNotificationCenter: NotificationCenter?
    @ObservationIgnored
    private var workspaceLifecycleObserverTokens: [NSObjectProtocol] = []
    private var workspaceActivity = WorkspaceActivityState.active
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests || isRunningUITest else { return }
        // Apple can publish sessionDidResignActive after will-finish and
        // before did-finish when the app launches in a switched-out login
        // session. Register here so the store-open provider receives the
        // authoritative initial session fact.
        installWorkspaceLifecycleObservation()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests || isRunningUITest else { return }

        // App Intents can be invoked immediately after process launch. Install
        // its framework-owned dependency provider before the did-finish store,
        // status-item, and hot-key work. The earlier workspace observers only
        // establish the activity fact consumed by this same open flight; the
        // provider never opens another ModelContainer or creates another
        // History writer (V2-05 §6.5).
        AppIntentDependencyRegistration.registerProduction { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.resolveAppIntentHistoryIngress()
        }

        installStatusItem()
        startSummonShortcut()
        openCompositionIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopSummonShortcut()
        removeWorkspaceLifecycleObservation()
        compositionOpenAttempt?.task.cancel()
#if CLIPY_UDS_F0
        unixSocketF0Listener?.stop()
        unixSocketF0Listener = nil
#endif
        composition?.stop()
    }

    /// Card 14C app-activation boundary. App deactivation is not an
    /// `NSWorkspace` login-session resignation, so it retires only the
    /// sensitive panel/browsing session. The app-owned clipboard observer
    /// remains live, and a later activation does not reopen the panel.
    func applicationDidResignActive(_ notification: Notification) {
        closePanel()
    }

    /// Card 14C screen-parameter boundary. AppKit supplies no change payload,
    /// and `NSScreen.screens` / `visibleFrame` are explicitly current facts,
    /// so re-read them for every notification. A still-reachable panel keeps
    /// its one browsing session. A panel stranded outside every current safe
    /// drawing area closes through the existing sole lifecycle owner; only a
    /// later explicit summon starts a fresh session using new screen facts.
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        guard let panel,
              panel.isPresented,
              !panel.isReachable(
                  in: NSScreen.screens.map(\.visibleFrame)
              )
        else { return }
        closePanel()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !Self.isRunningTests || isRunningUITest else { return }
        // System Settings may have changed registration/approval while Clipy
        // was inactive. Re-read the authoritative value; no cached Bool is
        // allowed to survive activation (REVIEW Card 10C).
        launchAtLoginController.refresh()
    }

    // MARK: - Workspace power / login-session lifecycle

    /// Apple requires power and login-session observers to use the workspace's
    /// own notification center. Delivery is requested on the main operation
    /// queue, so the callback can synchronously enter this MainActor owner.
    private func installWorkspaceLifecycleObservation() {
        guard workspaceLifecycleObserverTokens.isEmpty else { return }
        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter
        workspaceLifecycleNotificationCenter = notificationCenter
        workspaceLifecycleObserverTokens = [
            notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: workspace,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.workspaceWillSleep()
                }
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: workspace,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.workspaceDidWake()
                }
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: workspace,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.workspaceSessionDidResignActive()
                }
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: workspace,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.workspaceSessionDidBecomeActive()
                }
            },
        ]
    }

    private func removeWorkspaceLifecycleObservation() {
        guard let workspaceLifecycleNotificationCenter else { return }
        for token in workspaceLifecycleObserverTokens {
            workspaceLifecycleNotificationCenter.removeObserver(token)
        }
        workspaceLifecycleObserverTokens.removeAll()
        self.workspaceLifecycleNotificationCenter = nil
    }

    /// `willSleep` has a bounded synchronous effect: retire sensitive panel
    /// state and stop the existing capture observer. It never waits for
    /// History I/O or attempts to delay system sleep.
    private func workspaceWillSleep() {
        applyWorkspaceActivity(WorkspaceActivityState(
            isSystemAwake: false,
            isLoginSessionActive: workspaceActivity.isLoginSessionActive
        ))
    }

    /// Wake is not a clipboard event. The composition baselines the current
    /// generation and waits for a later change; reopening remains an explicit
    /// summon rather than a side effect of the power notification.
    private func workspaceDidWake() {
        applyWorkspaceActivity(WorkspaceActivityState(
            isSystemAwake: true,
            isLoginSessionActive: workspaceActivity.isLoginSessionActive
        ))
    }

    private func workspaceSessionDidResignActive() {
        applyWorkspaceActivity(WorkspaceActivityState(
            isSystemAwake: workspaceActivity.isSystemAwake,
            isLoginSessionActive: false
        ))
    }

    private func workspaceSessionDidBecomeActive() {
        applyWorkspaceActivity(WorkspaceActivityState(
            isSystemAwake: workspaceActivity.isSystemAwake,
            isLoginSessionActive: true
        ))
    }

    /// Power and login-session facts enter through one AppDelegate owner and
    /// one composition consumer. Any inactive fact closes sensitive UI;
    /// becoming active only baselines capture and never reopens the panel.
    private func applyWorkspaceActivity(_ activity: WorkspaceActivityState) {
        guard activity != workspaceActivity else { return }
        workspaceActivity = activity
        if !activity.permitsProductActivity {
            closePanel()
        }
        composition?.updateWorkspaceActivity(activity)
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
        guard workspaceActivity.permitsProductActivity else { return }
        if panel == nil {
            panel = FloatingPanel(
                rootView: PanelRootView(appDelegate: self),
                previewState: previewState,
                onPreviewPlacementChange: { [weak self] placement in
                    self?.previewPlacement = placement
                },
                isSelectionSubmissionEnabled: { [weak self] in
                    guard let self,
                          let composition = self.composition,
                          let panelSurfaceState = self.panelSurfaceState,
                          panelSurfaceState.isAtListRoot
                    else { return false }
                    return panelSurfaceState.selectedReference(
                        in: composition.viewState.rows
                    ) != nil
                },
                onSubmitSelection: { [weak self] in
                    self?.submitPanelSelection()
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

    private func submitPanelSelection() {
        guard let composition,
              let reference = panelSurfaceState?.selectedReference(
                  in: composition.viewState.rows
              )
        else { return }
        composition.viewState.requestPaste(reference)
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
            composition?.resumeCapture()
        case .retry:
            composition?.retryCaptureAccess()
        case nil:
            break
        }
    }

    /// The panel's explicit user-owned Pause intent. Only the authoritative
    /// allowed state exposes this action; all transitions remain owned by the
    /// existing composition capture-access reducer.
    func pauseCapture() {
        guard captureAccessState == .allowed else { return }
        composition?.pauseCapture()
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

    /// DATA-14 explicit recovery. A genuine failure is terminal until the
    /// user asks to retry; clearing it here admits exactly one new open flight.
    /// `AppComposition.open` already releases its same-process reservation on
    /// failure, so this never creates a second writer or a fallback store.
    func retryCompositionOpen() {
        guard composition == nil,
              compositionOpenAttempt == nil,
              openFailure != nil else { return }
        openFailure = nil
        openCompositionIfNeeded()
    }

    /// Reveals the directory containing the exact attempted store locator.
    /// This is intentionally read-only: no file is moved, deleted, repaired,
    /// or replaced, and no unstable underlying error text selects behavior.
    func revealStoreLocation() {
#if DEBUG
        if let markerURL = runningUITestConfiguration?.storeRevealMarkerURL {
            // Exact running-app evidence boundary: the control is real, but
            // Finder is replaced with one content-free, no-overwrite file
            // publication beside the test StoreRoot. No store path or error
            // text is written into the marker.
            try? Data().write(to: markerURL, options: .withoutOverwriting)
            return
        }
#endif
        revealStoreLocationOperation(
            compositionStoreURL.deletingLastPathComponent()
        )
    }

    private var compositionStoreURL: URL {
#if DEBUG
        runningUITestConfiguration?.storeURL ?? storeURL
#else
        storeURL
#endif
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
            let storeURL = compositionStoreURL
#if DEBUG
            let runningUITestConfiguration = self.runningUITestConfiguration
#endif
            let workspaceActivityProvider:
                @MainActor @Sendable () -> WorkspaceActivityState = {
                    [weak self] in
                    self?.workspaceActivity ?? WorkspaceActivityState(
                        isSystemAwake: false,
                        isLoginSessionActive: false
                    )
                }
            let started = Task { @MainActor in
#if DEBUG
                if let configuration = runningUITestConfiguration {
                    return try await AppComposition.openForUITesting(
                        storeURL: configuration.storeURL,
                        initialCaptureAccessBehavior:
                            configuration.initialCaptureAccessBehavior,
                        currentCaptureAccessBehavior:
                            configuration.currentCaptureAccessBehavior,
                        capturePauseDuration:
                            configuration.capturePauseDuration,
                        editorJourney: configuration.editorJourney,
                        workspaceActivityProvider: workspaceActivityProvider
                    )
                }
#endif
                return try await AppComposition.open(
                    storeURL: storeURL,
                    workspaceActivityProvider: workspaceActivityProvider
                )
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
                summonPanelForRunningUITestIfNeeded()
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
#if DEBUG
                summonPanelForRunningUITestIfNeeded()
#endif
            }
            throw error
        }
    }

#if DEBUG
    /// Running-app journeys need the same real floating panel for both launch
    /// success and launch failure. The one-shot controller action mirrors the
    /// existing successful-launch seam and never exists in Release.
    private func summonPanelForRunningUITestIfNeeded() {
        guard runningUITestConfiguration != nil,
              isRunningUITestSummonPending else { return }
        isRunningUITestSummonPending = false
        summonShortcutController.fireActionForTesting()
    }
#endif

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
        opened.viewState.onSettledSearchResultCount = {
            [weak self] count,
            hasNextPage in
            self?.accessibilityAnnouncement
                .announceSettledSearchResultCount(
                    count,
                    hasNextPage: hasNextPage
                )
        }
        opened.onCaptureHealthChanged = { [weak self] health in
            self?.receiveCaptureHealth(health)
        }
        opened.onCaptureAccessStateChanged = { [weak self] state in
            self?.receiveCaptureAccessState(state)
        }
        composition = opened
        opened.updateWorkspaceActivity(workspaceActivity)
        // A failure panel can already be visible when an explicit Retry
        // succeeds. Join that existing window to the newly opened composition
        // just as `openPanel` would, so the History view starts its first
        // authoritative observation without closing/reopening the panel.
        if panel?.isPresented == true {
            opened.viewState.activate()
            panelSurfaceState.beginSession(rows: opened.viewState.rows)
        }
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

    /// Keeps the panel and the always-visible menu-bar affordance on the same
    /// composition-owned privacy state. This is presentation only; the status
    /// item never owns or drives the deadline.
    private func receiveCaptureAccessState(_ state: CaptureAccessState) {
        captureAccessState = state
        updateStatusItemImage()
    }

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

    /// Hosted panel-lifecycle entry through the real AppDelegate owner. The
    /// hook is absent from Release; tests still exercise the production lazy
    /// panel construction, callbacks, and session/view-state ownership.
    func openPanelForTesting(at mode: PopupPositionMode = .center) {
        openPanel(at: mode)
    }

    /// Installs/removes the same observer wiring as production. Hosted tests
    /// post Apple's exact names with the documented shared-workspace object.
    func installWorkspaceLifecycleObservationForTesting() {
        installWorkspaceLifecycleObservation()
    }

    func removeWorkspaceLifecycleObservationForTesting() {
        removeWorkspaceLifecycleObservation()
    }

    var panelForTesting: FloatingPanel? { panel }

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
            button.action = #selector(statusItemClicked)
            button.target = self
        }
        statusItem = item
        updateStatusItemImage()
    }

    private func updateStatusItemImage() {
        let isPaused = captureAccessState == .userPaused
        let symbolName = statusItemSymbolName
        let accessibilityLabel = isPaused
            ? "Clipy, clipboard monitoring paused"
            : "Clipy"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )
        statusItem?.button?.image = image
#if DEBUG
        if let image,
           statusItem?.button?.image === image {
            appliedStatusItemSymbolNameForTesting = symbolName
        } else {
            appliedStatusItemSymbolNameForTesting = nil
        }
#endif
        // The image description gives assistive technology a fallback, while
        // the status-bar button's explicit label is the stable AX surface.
        statusItem?.button?.setAccessibilityLabel(accessibilityLabel)
    }

    private var statusItemSymbolName: String {
        captureAccessState == .userPaused ? "pause.circle" : "list.clipboard"
    }

#if DEBUG
    /// Hosted CLIP-1 evidence installs only the production status item and
    /// reads its public AX label. The ordinary test-host launch guard still
    /// prevents incidental status-bar, hot-key, or store side effects.
    func installStatusItemForTesting() {
        installStatusItem()
    }

    func removeStatusItemForTesting() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        appliedStatusItemSymbolNameForTesting = nil
    }

    var statusItemAccessibilityLabelForTesting: String? {
        statusItem?.button?.accessibilityLabel()
    }

    var statusItemHasImageForTesting: Bool {
        statusItem?.button?.image != nil
    }

    var statusItemSymbolNameForTesting: String? {
        appliedStatusItemSymbolNameForTesting
    }
#endif

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

    /// Production launch and hosted integration tests enter the same app-owned
    /// registration lifecycle. A saved conflict remains unavailable: the
    /// controller does not silently fall back to the default chord.
    @discardableResult
    func startSummonShortcut() -> Bool {
        let registered = summonShortcutController.start()
        refreshSummonShortcutPresentation()
        return registered
    }

    private func stopSummonShortcut() {
        summonShortcutController.stop()
        refreshSummonShortcutPresentation()
    }

    private func retrySummonShortcut() {
        summonShortcutController.retry()
        refreshSummonShortcutPresentation()
    }

    private func resetSummonShortcut() {
        summonShortcutController.reset()
        refreshSummonShortcutPresentation()
    }

    private func refreshSummonShortcutPresentation() {
        let status: SummonShortcutStatus
        switch summonShortcutController.state {
        case .stopped:
            status = .stopped
        case .active(let chord):
            status = .current(chord.settingsDisplayName)
        case .unavailable(let requested, let retainedActive):
            status = .unavailable(
                requested: requested.settingsDisplayName,
                retainedCurrent: retainedActive?.settingsDisplayName
            )
        }
        let warning: SummonShortcutWarning?
        switch summonShortcutController.state.warning {
        case .knownColorsShortcut:
            warning = .showColorsConflict
        case nil:
            warning = nil
        }
        summonShortcutPresentation = SummonShortcutSettings(
            status: status,
            warning: warning
        )
    }

    /// Immutable neutral status plus the two recovery intents approved by the
    /// Card 14B decision. Chord recording/editing remains outside this slice.
    func summonShortcutBinding() -> SummonShortcutSettings {
        SummonShortcutSettings(
            status: summonShortcutPresentation.status,
            warning: summonShortcutPresentation.warning,
            retry: { [weak self] in self?.retrySummonShortcut() },
            reset: { [weak self] in self?.resetSummonShortcut() }
        )
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
