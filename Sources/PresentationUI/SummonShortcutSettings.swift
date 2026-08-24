/// Framework-neutral presentation for Clipy's app-owned summon shortcut
/// (REVIEW Card 14B). Carbon key codes, registration tokens, and UserDefaults
/// remain in ClipyApp; Settings receives only display facts and narrow recovery
/// intents.

/// The registration posture visible in General Settings. `unavailable` keeps
/// the requested chord distinct from a still-working old chord, because a
/// failed change must never make the retained binding look lost.
public enum SummonShortcutStatus: Sendable, Equatable {
    case stopped
    case current(String)
    case unavailable(requested: String, retainedCurrent: String?)
}

/// The one approved advisory warning. The documented default remains usable;
/// this is not a registry of system shortcuts or a rejection policy.
public enum SummonShortcutWarning: Sendable, Equatable {
    case showColorsConflict
}

/// One immutable snapshot plus Retry and Reset intents. A snapshot never
/// reports framework errors or Carbon identifiers across the app/UI boundary.
public struct SummonShortcutSettings: Sendable {
    public let status: SummonShortcutStatus
    public let warning: SummonShortcutWarning?

    private let retryAction: @MainActor @Sendable () -> Void
    private let resetAction: @MainActor @Sendable () -> Void

    public init(
        status: SummonShortcutStatus,
        warning: SummonShortcutWarning? = nil,
        retry: @escaping @MainActor @Sendable () -> Void = {},
        reset: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.status = status
        self.warning = warning
        retryAction = retry
        resetAction = reset
    }

    public var canRetry: Bool {
        if case .unavailable = status { return true }
        return false
    }

    public var canReset: Bool {
        status != .stopped
    }

    @MainActor
    public func retry() {
        guard canRetry else { return }
        retryAction()
    }

    @MainActor
    public func reset() {
        guard canReset else { return }
        resetAction()
    }
}
