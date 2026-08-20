/// GlobalHotKey.swift — the global ⌘⇧C summon hotkey: a minimal Carbon
/// `RegisterEventHotKey` wrapper (the same mechanism Maccy uses through the
/// KeyboardShortcuts package — replicated WITHOUT adding a dependency, per
/// docs/roadmap/07-external-deps.md's no-new-dependencies rule).
///
/// Carbon hotkeys are the one global-shortcut API that needs no
/// accessibility grant (`NSEvent.addGlobalMonitorForEvents` cannot deliver
/// key events to an untrusted agent process), which is why every clipboard
/// panel lands here. The handler runs on the app's main runloop (Carbon
/// dispatches event-dispatcher-target handlers on the main thread), so the
/// action is invoked under `MainActor.assumeIsolated`.
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
/// Carbon dispatches event-dispatcher-target handlers on the main runloop
/// thread, so the main-actor hop is a compile-time assertion of an
/// established runtime fact (`MainActor.assumeIsolated`), not a context
/// switch. Foreign hotkey IDs (another app's chord, or a sibling
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
    let handled = MainActor.assumeIsolated { () -> Bool in
        guard pressedID.id == hotKey.matchingID,
              pressedID.signature == hotKey.matchingSignature
        else { return false }
        hotKey.fire()
        return true
    }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
