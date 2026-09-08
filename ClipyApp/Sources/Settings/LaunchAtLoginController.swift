/// App-owned ServiceManagement boundary and single-operation state owner
/// (REVIEW Card 10C). PresentationUI sees only `LaunchAtLoginSettings`.
import Foundation
import PresentationUI
import ServiceManagement

/// Neutral internal copy of the complete macOS 26 `SMAppService.Status`
/// vocabulary. `unknown` fails closed to unavailable presentation if a future
/// SDK adds a case.
enum LaunchAtLoginSystemStatus: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

/// The narrow true-external operations adapter. It mirrors the four platform
/// operations Clipy actually performs instead of introducing a generic service
/// protocol or allowing tests to mutate `SMAppService.mainApp`.
@MainActor
struct LaunchAtLoginOperations {
    let status: @MainActor () -> LaunchAtLoginSystemStatus
    let register: @MainActor () async throws -> Void
    let unregister: @MainActor () async throws -> Void
    let openSystemSettings: @MainActor () -> Void

    static let live: LaunchAtLoginOperations = {
#if DEBUG
        if let runningUITest = runningUITestOperations() {
            return runningUITest
        }
#endif
        return LaunchAtLoginOperations(
            status: {
                switch SMAppService.mainApp.status {
                case .notRegistered:
                    .notRegistered
                case .enabled:
                    .enabled
                case .requiresApproval:
                    .requiresApproval
                case .notFound:
                    .notFound
                @unknown default:
                    .unknown
                }
            },
            register: {
                try SMAppService.mainApp.register()
            },
            unregister: {
                try SMAppService.mainApp.unregister()
            },
            openSystemSettings: {
                SMAppService.openSystemSettingsLoginItems()
            }
        )
    }()

#if DEBUG
    /// Running-app acceptance substitutes only ServiceManagement's true
    /// external edge. The real controller, immutable Presentation value,
    /// Settings scene, Toggle, and recovery Button remain production paths.
    /// Release never reads this launch envelope (review Card 10C).
    private static func runningUITestOperations(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchAtLoginOperations? {
        guard environment["CLIPY_RUNNING_UI_TEST"] == "1",
              environment["CLIPY_UI_TEST_LAUNCH_AT_LOGIN_STATUS"]
                == "requires-approval",
              let markerPath = environment[
                  "CLIPY_UI_TEST_LOGIN_ITEMS_SETTINGS_MARKER_PATH"
              ],
              markerPath.hasPrefix("/"),
              let storePath = environment["CLIPY_UI_TEST_STORE_PATH"],
              storePath.hasPrefix("/")
        else { return nil }

        let markerURL = URL(fileURLWithPath: markerPath).standardizedFileURL
        let storeURL = URL(fileURLWithPath: storePath).standardizedFileURL
        guard markerURL.lastPathComponent == "login-items-settings-opened",
              markerURL.deletingLastPathComponent()
                == storeURL.deletingLastPathComponent()
        else { return nil }

        let state = RunningUITestLaunchAtLoginState(
            markerURL: markerURL
        )
        return state.operations
    }
#endif
}

#if DEBUG
/// Mutable only inside the injected true-external boundary. It lets one real
/// Settings process prove both approval recovery choices without launching a
/// signed service or System Settings on the shared CI host.
@MainActor
private final class RunningUITestLaunchAtLoginState {
    private enum Failure: Error {
        case serviceUnavailable
    }

    private var status: LaunchAtLoginSystemStatus = .requiresApproval
    private let markerURL: URL

    init(markerURL: URL) {
        self.markerURL = markerURL
    }

    var operations: LaunchAtLoginOperations {
        LaunchAtLoginOperations(
            status: { self.status },
            register: { self.status = .enabled },
            unregister: {
                if self.status == .requiresApproval {
                    self.status = .notRegistered
                } else {
                    self.status = .notFound
                    throw Failure.serviceUnavailable
                }
            },
            openSystemSettings: { [markerURL] in
                // Publication is a one-shot observation, never permission to
                // replace a pre-existing file even inside the admitted temp
                // StoreRoot sibling directory.
                try? Data().write(
                    to: markerURL,
                    options: .withoutOverwriting
                )
            }
        )
    }
}
#endif

/// Main-actor owner for authoritative status refresh and register/unregister
/// attempts. Appearance/activation refreshes observe the system without
/// cancelling an explicit user request or admitting a second operation.
@MainActor
final class LaunchAtLoginController {
    private let operations: LaunchAtLoginOperations

    private(set) var presentation: LaunchAtLoginSettings

    var onPresentationChanged:
        (@MainActor (LaunchAtLoginSettings) -> Void)? {
        didSet { onPresentationChanged?(presentation) }
    }

    init(operations: LaunchAtLoginOperations) {
        self.operations = operations
        self.presentation = LaunchAtLoginSettings(
            state: Self.presentationState(for: operations.status())
        )
    }

    /// Card 10C: external changes refresh the displayed system status and
    /// clear a settled error. An outstanding registration change remains
    /// pending: cancellation cannot undo its external side effect, and its
    /// completion must still publish a fresh authoritative status.
    func refresh() {
        publish(
            state: Self.presentationState(for: operations.status()),
            operationFailed: false,
            operationPending: presentation.operationPending
        )
    }

    func setEnabled(_ enabled: Bool) {
        guard !presentation.operationPending,
              presentation.state != .unavailable else { return }
        // Card 10C: preserve authoritative status while the system operation
        // runs, clear the previous attempt's error, and disable repeat input.
        publish(
            state: presentation.state,
            operationFailed: false,
            operationPending: true
        )
        let operations = self.operations
        Task { [weak self] in
            do {
                if enabled {
                    try await operations.register()
                } else {
                    try await operations.unregister()
                }
                guard let self else { return }
                publish(
                    state: Self.presentationState(for: operations.status()),
                    operationFailed: false
                )
            } catch {
                guard let self else { return }
                // Preserve only the fresh authoritative status plus a
                // content-free episode bit; framework errors never cross.
                publish(
                    state: Self.presentationState(for: operations.status()),
                    operationFailed: true
                )
            }
        }
    }

    func openSystemSettings() {
        guard presentation.state == .requiresApproval else { return }
        operations.openSystemSettings()
    }

    private func publish(
        state: LaunchAtLoginState,
        operationFailed: Bool,
        operationPending: Bool = false
    ) {
        presentation = LaunchAtLoginSettings(
            state: state,
            operationFailed: operationFailed,
            operationPending: operationPending
        )
        onPresentationChanged?(presentation)
    }

    private static func presentationState(
        for status: LaunchAtLoginSystemStatus
    ) -> LaunchAtLoginState {
        switch status {
        case .notRegistered:
            .off
        case .enabled:
            .on
        case .requiresApproval:
            .requiresApproval
        case .notFound, .unknown:
            .unavailable
        }
    }
}
