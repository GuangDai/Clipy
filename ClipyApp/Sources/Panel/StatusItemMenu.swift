/// StatusItemMenu.swift — the status item's secondary-click (right-click)
/// menu. The primary click keeps summoning/dismissing the panel
/// byte-identically; only an actual right-mouse event routes to the menu
/// (see `StatusItemClickDecision`).
///
/// The menu is presentation only and owns no state: "Show Clipboard
/// History" reuses the primary-click summon path, Pause/Resume routes
/// through the SAME composition-owned transitions as the panel's
/// `clipy.capture.pause` row (AppDelegate.pauseCapture) and the access
/// banner's Resume recovery (AppDelegate.recoverCaptureAccess), "Settings…"
/// invokes the same public OpenSettingsAction the panel footer uses, and
/// "Quit Clipy" is `NSApp.terminate`. The one state-dependent title is
/// recomputed in `menuNeedsUpdate` so it never survives a capture-pause
/// transition.
import AppKit

/// The two dispositions a status-item activation can take — the same
/// pure-decision idiom as `PanelKeyEventDecision` (FloatingPanel.swift):
/// a testable routing fact kept separate from the AppKit side effect.
enum StatusItemClickDisposition: Equatable {
    /// Primary activation: today's summon/dismiss toggle, unchanged.
    case togglePanel
    /// Secondary activation: pop the context menu at the status item.
    case showMenu
}

enum StatusItemClickDecision {
    /// Only an actual right-mouse-up diverts to the menu. A nil event
    /// (programmatic action invocations, which have no mouse event being
    /// processed) or any other event type keeps the pre-menu primary-click
    /// behavior for every non-right activation.
    static func disposition(
        eventType: NSEvent.EventType?
    ) -> StatusItemClickDisposition {
        eventType == .rightMouseUp ? .showMenu : .togglePanel
    }
}

/// Builds and owns the lazily constructed NSMenu. The AppDelegate retains
/// this controller; the menu itself is attached to the status item only
/// for the duration of one pop-up — the AppDelegate clears
/// `statusItem.menu` from the did-close callback below, because a
/// permanently assigned menu would hijack EVERY click (AppKit suppresses
/// the button action whenever a menu is set) and the primary click must
/// keep summoning the panel.
@MainActor
final class StatusItemMenu: NSObject, NSMenuDelegate {
    /// The built menu. Item layout (pinned by hosted tests): "Show
    /// Clipboard History", the Pause/Resume item, a separator,
    /// "Settings…", a separator, "Quit Clipy".
    let menu: NSMenu

    /// The one state-dependent item, retained so `refresh()` can rewrite
    /// its title/enabled state in place.
    private let pauseResumeItem: NSMenuItem

    private let isCapturePaused: @MainActor () -> Bool
    private let canToggleCapturePause: @MainActor () -> Bool
    private let onShowHistory: @MainActor () -> Void
    private let onToggleCapturePause: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void
    private let onMenuDidClose: @MainActor () -> Void

    init(
        isCapturePaused: @escaping @MainActor () -> Bool,
        canToggleCapturePause: @escaping @MainActor () -> Bool,
        onShowHistory: @escaping @MainActor () -> Void,
        onToggleCapturePause: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void,
        onMenuDidClose: @escaping @MainActor () -> Void
    ) {
        self.isCapturePaused = isCapturePaused
        self.canToggleCapturePause = canToggleCapturePause
        self.onShowHistory = onShowHistory
        self.onToggleCapturePause = onToggleCapturePause
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
        self.onMenuDidClose = onMenuDidClose
        let pauseResumeItem = NSMenuItem(
            title: "Pause Clipboard Monitoring",
            action: #selector(toggleCapturePauseClicked(_:)),
            keyEquivalent: ""
        )
        self.pauseResumeItem = pauseResumeItem
        let menu = NSMenu()
        // Validation is manual: the Pause/Resume item's enabled state is
        // owned by `refresh()`, not by responder-chain validation.
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(
            title: "Show Clipboard History",
            action: #selector(showHistoryClicked(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(pauseResumeItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsClicked(_:)),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Clipy",
            action: #selector(quitClicked(_:)),
            keyEquivalent: ""
        ))
        self.menu = menu
        super.init()
        for item in menu.items where !item.isSeparatorItem {
            item.target = self
        }
        menu.delegate = self
        refresh()
    }

    /// Recomputes the one state-dependent item from the owner's live facts.
    /// Called at build time and by AppKit on every `menuNeedsUpdate`
    /// (before each presentation), so a stale title can never be shown.
    /// `NSMenu.update()` is NOT a refresh entry: it only applies
    /// NSMenuValidation enable/disable state.
    func refresh() {
        pauseResumeItem.title = isCapturePaused()
            ? "Resume Clipboard Monitoring"
            : "Pause Clipboard Monitoring"
        pauseResumeItem.isEnabled = canToggleCapturePause()
    }

    // MARK: - NSMenuDelegate

    // `nonisolated` witnesses + an explicit main-actor hop: the delegate
    // methods are called by AppKit's menu machinery on the main thread, and
    // this spelling satisfies the protocol whether or not the SDK annotates
    // NSMenuDelegate itself as `@MainActor`.
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            refresh()
        }
    }

    /// The pop-up is over: hand the status item back to click routing so
    /// the next primary click summons instead of reopening the menu.
    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            onMenuDidClose()
        }
    }

    // MARK: - Item actions (pure forwards; no menu-owned state)

    @objc private func showHistoryClicked(_ sender: NSMenuItem) {
        onShowHistory()
    }

    @objc private func toggleCapturePauseClicked(_ sender: NSMenuItem) {
        onToggleCapturePause()
    }

    @objc private func openSettingsClicked(_ sender: NSMenuItem) {
        onOpenSettings()
    }

    @objc private func quitClicked(_ sender: NSMenuItem) {
        onQuit()
    }
}
