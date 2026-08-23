/// AppIntentDependencyRegistration.swift — the sole framework-owned
/// dependency registration point for Clipy's App Intents surface.
/// Owning spec: docs/v2/V2-05-external-gateway.md §6.5–§6.6 and
/// docs/v2/V2-roadmap.md X.7 (`PLAY-PY-B0I`, `X-COMPILE-2/3/4`).
import AppIntents
import HistoryCore
import HistoryStorage

/// Registers the one connection-bound External History facade provider.
/// The async overload is intentional: App Intents may ask before the store
/// has finished opening, and Swift 6 requires this provider to have explicit
/// Sendable isolation rather than inheriting the caller's MainActor.
enum AppIntentDependencyRegistration {
    typealias Provider = @Sendable () async throws -> ExternalHistoryFacade

    /// Production's only access to AppDependencyManager's global manager.
    /// AppDelegate calls this synchronously before beginning the store open.
    static func registerProduction(
        provider unresolvedProvider: @escaping Provider
    ) {
        let provider = storeAvailabilityProvider(unresolvedProvider)
        AppDependencyManager.shared.add(dependency: provider)
    }

    /// Standalone-manager seam documented by Apple for hosted testing. The
    /// returned closure is the exact provider registered with the framework,
    /// allowing hosted tests to prove logical cold/warm behavior without
    /// claiming a Siri/Shortcuts system invocation.
    @discardableResult
    static func register(
        in manager: AppDependencyManager,
        provider: @escaping Provider
    ) -> Provider {
        let mapped = storeAvailabilityProvider(provider)
        manager.add(dependency: mapped)
        return mapped
    }

    /// Maps startup and owner-lifetime failures to a retryable, content-free
    /// External Gateway result. The UI retains the underlying error in its
    /// own app-shell state; it never crosses this external boundary.
    static func storeAvailabilityProvider(
        _ provider: @escaping Provider
    ) -> Provider {
        {
            do {
                return try await provider()
            } catch {
                throw ExternalFailure.temporarilyUnavailable(.storeLocked)
            }
        }
    }
}
