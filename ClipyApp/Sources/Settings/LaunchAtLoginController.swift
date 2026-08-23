/// App-owned ServiceManagement boundary and generation-fenced state owner
/// (REVIEW Card 10C). PresentationUI sees only `LaunchAtLoginSettings`.
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

    static let live = LaunchAtLoginOperations(
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
}

/// Main-actor owner for authoritative status refresh and register/unregister
/// attempts. A reference token fences noncooperative stale completions; no
/// wrapping generation counter or global service state is introduced.
@MainActor
final class LaunchAtLoginController {
    private final class OperationGeneration {}

    private let operations: LaunchAtLoginOperations
    private var generation = OperationGeneration()
    private var operationTask: Task<Void, Never>?

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

    /// External state changes (Settings appearance/app activation) supersede
    /// every older operation completion and clear its episode-level error.
    func refresh() {
        generation = OperationGeneration()
        operationTask?.cancel()
        operationTask = nil
        publish(
            state: Self.presentationState(for: operations.status()),
            operationFailed: false
        )
    }

    func setEnabled(_ enabled: Bool) {
        let operationGeneration = OperationGeneration()
        generation = operationGeneration
        operationTask?.cancel()
        let operations = self.operations
        operationTask = Task { [weak self] in
            do {
                if enabled {
                    try await operations.register()
                } else {
                    try await operations.unregister()
                }
                guard let self,
                      generation === operationGeneration else { return }
                operationTask = nil
                publish(
                    state: Self.presentationState(for: operations.status()),
                    operationFailed: false
                )
            } catch {
                guard let self,
                      generation === operationGeneration else { return }
                operationTask = nil
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
        operationFailed: Bool
    ) {
        presentation = LaunchAtLoginSettings(
            state: state,
            operationFailed: operationFailed
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
