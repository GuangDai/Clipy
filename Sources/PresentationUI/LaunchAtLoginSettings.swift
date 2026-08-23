/// Framework-neutral launch-at-login presentation value (REVIEW Card 10C).
/// ServiceManagement remains confined to ClipyApp; this target receives only
/// immutable state and narrow user-intent closures.

/// The four authoritative registration/authorization states exposed by the
/// settings surface. `requiresApproval` is registered, but not equivalent to
/// enabled; `unavailable` is not ordinary off.
public enum LaunchAtLoginState: Sendable, Equatable {
    case off
    case on
    case requiresApproval
    case unavailable
}

/// One immutable settings snapshot plus its three caller intents. Operation
/// failure is deliberately content-free: it preserves the last authoritative
/// state without retaining an NSError, service URL, or localized framework
/// description across the UI boundary.
public struct LaunchAtLoginSettings: Sendable {
    public let state: LaunchAtLoginState
    public let operationFailed: Bool

    private let setEnabledAction: @MainActor @Sendable (Bool) -> Void
    private let refreshAction: @MainActor @Sendable () -> Void
    private let openSystemSettingsAction: @MainActor @Sendable () -> Void

    public init(
        state: LaunchAtLoginState,
        operationFailed: Bool = false,
        setEnabled: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
        refresh: @escaping @MainActor @Sendable () -> Void = {},
        openSystemSettings: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.state = state
        self.operationFailed = operationFailed
        self.setEnabledAction = setEnabled
        self.refreshAction = refresh
        self.openSystemSettingsAction = openSystemSettings
    }

    public var isOn: Bool {
        state == .on || state == .requiresApproval
    }

    public var canToggle: Bool {
        state != .unavailable
    }

    public var canOpenSystemSettings: Bool {
        state == .requiresApproval
    }

    @MainActor
    public func setEnabled(_ enabled: Bool) {
        setEnabledAction(enabled)
    }

    @MainActor
    public func refresh() {
        refreshAction()
    }

    @MainActor
    public func openSystemSettings() {
        guard canOpenSystemSettings else { return }
        openSystemSettingsAction()
    }
}
