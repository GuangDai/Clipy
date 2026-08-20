/// GlobalHotKey.swift — the global ⌘⇧C summon hotkey: a minimal Carbon
/// `RegisterEventHotKey` wrapper (the same mechanism Maccy uses through the
/// KeyboardShortcuts package — replicated WITHOUT adding a dependency, per
/// docs/roadmap/07-external-deps.md's no-new-dependencies rule).
///
/// Carbon hotkeys are the one global-shortcut API that needs no
/// accessibility grant (`NSEvent.addGlobalMonitorForEvents` cannot deliver
/// key events to an untrusted agent process), which is why every clipboard
/// panel lands here. The action is invoked under MainActor isolation; the
/// MainActor's executor is the main thread, but Apple publishes no
/// symbol-level guarantee that Carbon invokes an event-dispatcher-target
/// handler on that thread (audit S-6,
/// docs/reviews/2026-08-20-clipy-maccy-audit/01-standards.md), so the C
/// callback below checks `Thread.isMainThread` at runtime and block-hops
/// through the main queue when the expectation ever fails — per
/// docs/00-overview.md §5 the required outcome (MainActor-isolated firing)
/// is enforced, not assumed.
///
/// Registration is process-lifetime (Maccy's `Popup.swift` design note:
/// repeatedly enabling/disabling a Carbon hotkey leaks handler slots), and
/// every press toggles the panel — the open/close decision lives with the
/// caller's action.
import Carbon.HIToolbox
import Foundation

/// One registered global hotkey. The action fires on the main actor for
/// every matching key press until `unregister()`.
@MainActor
final class GlobalHotKey {
    private let keyCode: UInt32
    private let modifiers: UInt32

    /// The Carbon hotkey identity (signature 'CLPY' + id) matched in the
    /// event handler so foreign hotkey events are passed on unhandled.
    private let hotKeyID: EventHotKeyID

    /// The action invoked on each hotkey press (the panel toggle at the
    /// call site).
    private let action: () -> Void

    /// The registered hotkey reference, non-nil while registered.
    private var hotKeyRef: EventHotKeyRef?

    /// The installed Carbon event handler, non-nil while installed.
    private var handlerRef: EventHandlerRef?

    /// - Parameters:
    ///   - keyCode: Carbon virtual key code (e.g. `kVK_ANSI_C`).
    ///   - modifiers: Carbon modifier mask (`cmdKey | shiftKey`).
    ///   - id: hotkey ID within the 'CLPY' signature namespace.
    ///   - action: invoked on the main actor per press.
    init(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        self.action = action
    }

    /// The 'CLPY' four-char signature namespacing Clipy's hotkey IDs.
    private static let signature: OSType = 0x434C_5059

    /// The default summon chord: ⇧⌘C (Maccy's `KeyboardShortcuts.Name.popup`
    /// default, `Shortcut(.c, modifiers: [.command, .shift])`).
    static func summonPanelHotKey(action: @escaping () -> Void) -> GlobalHotKey {
        GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(cmdKey | shiftKey),
            id: 1,
            action: action
        )
    }

    /// The identity the Carbon handler matches against (fileprivate so the
    /// file-local C handler can read it under `MainActor.assumeIsolated`).
    fileprivate var matchingID: UInt32 { hotKeyID.id }
    fileprivate var matchingSignature: OSType { hotKeyID.signature }

    /// Registers the hotkey and installs the event handler. A second call
    /// while registered is a no-op. Returns false when Carbon rejects the
    /// registration (e.g. the chord is taken by another app) — the caller
    /// degrades to menu-bar-only summon rather than crashing.
    @discardableResult
    func register() -> Bool {
        guard hotKeyRef == nil else { return true }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            globalHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )
        guard installStatus == noErr else { return false }

        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard registerStatus == noErr, let ref else {
            RemoveEventHandler(installedHandler)
            return false
        }
        handlerRef = installedHandler
        hotKeyRef = ref
        return true
    }

    /// Unregisters the hotkey and removes the event handler.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    /// Invokes the action; called by the Carbon handler after the hotkey ID
    /// match, already on the main actor. Internal (not fileprivate) so the
    /// hosted integration tests can drive the handler's tail end directly.
    func fire() {
        action()
    }
}

/// The Carbon hotkey-pressed handler shared by every `GlobalHotKey`.
/// No symbol-level Apple documentation fixes the dispatch thread of a
/// handler installed on `GetEventDispatcherTarget()` (audit S-6), so the
/// MainActor entry is chosen at runtime instead of assumed:
///
/// - Main thread (the expected case — the event dispatcher is driven by
///   the main runloop): `MainActor.assumeIsolated` is a no-cost assertion
///   of the documented MainActor-runs-on-the-main-thread executor
///   contract, not a context switch.
/// - Any other thread (unproven-premise fallback): the match-and-fire
///   block-hops through `DispatchQueue.main.sync`, so it still runs under
///   MainActor isolation and the handled/not-handled `OSStatus` answer
///   stays synchronous for Carbon.
///
/// Foreign hotkey IDs (another app's chord, or a sibling
/// registration) are passed on as `eventNotHandledErr`.
private func globalHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var pressedID = EventHotKeyID()
    let parameterStatus = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &pressedID
    )
    guard parameterStatus == noErr else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    // `GlobalHotKey` is a `@MainActor` class (implicitly Sendable), so the
    // reference crosses into the main-queue block without an escape hatch.
    let matchAndFire = { @MainActor () -> Bool in
        guard pressedID.id == hotKey.matchingID,
              pressedID.signature == hotKey.matchingSignature
        else { return false }
        hotKey.fire()
        return true
    }
    let handled: Bool
    if Thread.isMainThread {
        handled = MainActor.assumeIsolated(matchAndFire)
    } else {
        handled = DispatchQueue.main.sync {
            MainActor.assumeIsolated(matchAndFire)
        }
    }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
