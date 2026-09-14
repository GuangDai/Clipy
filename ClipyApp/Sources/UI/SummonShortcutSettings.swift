/// Framework-neutral presentation for Clipy's app-owned summon shortcut
/// (REVIEW Card 14B). Carbon key codes, registration tokens, and UserDefaults
/// remain in ClipyApp; Settings receives only display facts and narrow recovery
/// intents.

/// The registration posture visible in General Settings. `unavailable` keeps
/// the requested chord distinct from a still-working old chord, because a
/// failed change must never make the retained binding look lost.
enum SummonShortcutStatus: Sendable, Equatable {
    case stopped
    case disabled
    case current(String)
    case unavailable(requested: String, retainedCurrent: String?)
}

/// The one approved advisory warning. The documented default remains usable;
/// this is not a registry of system shortcuts or a rejection policy.
enum SummonShortcutWarning: Sendable, Equatable {
    case showColorsConflict
}

/// One immutable snapshot plus Change, Retry, and Reset intents. A snapshot
/// never reports framework errors, key codes, or Carbon identifiers across
/// the app/UI boundary; ClipyApp owns the concrete recorder and registration.
struct SummonShortcutSettings: Sendable {
    let status: SummonShortcutStatus
    let warning: SummonShortcutWarning?
    let currentPanelChord: PanelShortcutChord?
    let conflictingPanelAction: PanelShortcutAction?

    private let beginChangeAction: @MainActor @Sendable () -> Void
    private let retryAction: @MainActor @Sendable () -> Void
    private let resetAction: @MainActor @Sendable () -> Void
    private let clearAction: @MainActor @Sendable () -> Void
    private let beginRecordingAction: @MainActor @Sendable () -> Void
    private let endRecordingAction: @MainActor @Sendable () -> Void

    init(
        status: SummonShortcutStatus,
        warning: SummonShortcutWarning? = nil,
        currentPanelChord: PanelShortcutChord? = nil,
        conflictingPanelAction: PanelShortcutAction? = nil,
        beginChange: @escaping @MainActor @Sendable () -> Void = {},
        retry: @escaping @MainActor @Sendable () -> Void = {},
        reset: @escaping @MainActor @Sendable () -> Void = {},
        clear: @escaping @MainActor @Sendable () -> Void = {},
        beginRecording: @escaping @MainActor @Sendable () -> Void = {},
        endRecording: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.status = status
        self.warning = warning
        self.currentPanelChord = currentPanelChord
        self.conflictingPanelAction = conflictingPanelAction
        beginChangeAction = beginChange
        retryAction = retry
        resetAction = reset
        clearAction = clear
        beginRecordingAction = beginRecording
        endRecordingAction = endRecording
    }

    var canChange: Bool {
        status != .stopped
    }

    var canRetry: Bool {
        if case .unavailable = status { return true }
        return false
    }

    var canClear: Bool {
        status != .stopped && status != .disabled
    }

    /// Package (GOV-3): the Reset button is this module's Settings view;
    /// `reset()` guards on this the same way, in-module.
    var canReset: Bool {
        status != .stopped
    }

    @MainActor
    func beginChange() {
        guard canChange else { return }
        beginChangeAction()
    }

    @MainActor
    func retry() {
        guard canRetry else { return }
        retryAction()
    }

    @MainActor
    func reset() {
        guard canReset else { return }
        resetAction()
    }

    @MainActor
    func clear() {
        guard canClear else { return }
        clearAction()
    }

    /// Every Settings recorder suspends the global binding, including a
    /// panel-action recorder that may receive the same physical combination.
    @MainActor
    func beginRecording() {
        guard canChange else { return }
        beginRecordingAction()
    }

    @MainActor
    func endRecording() {
        endRecordingAction()
    }
}
