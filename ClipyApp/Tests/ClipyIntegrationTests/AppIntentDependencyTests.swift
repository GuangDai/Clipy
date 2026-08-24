/// Hosted evidence for X.7's App Intents dependency composition.
///
/// Apple documents `AppDependencyManager()` as the standalone testing seam.
/// These tests register the exact async provider used by production, then
/// invoke the retained provider directly. A deterministic actor gate parks
/// the one real in-memory History open so the first provider call demonstrably
/// waits on in-flight startup. That proves logical cold/warm store-facade
/// behavior and content-free startup mapping without claiming a Siri/Shortcuts
/// framework invocation; signed system resolution remains a separate runtime
/// acceptance cell (V2-05 §6.5–§6.6).
import AppIntents
import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import ClipyApp

@Suite("App Intents dependency composition (X.7)")
struct AppIntentDependencyTests {
    @Test("registered provider works cold and observes later grants when warm")
    func registeredProviderUsesOneLiveFacadeAcrossColdAndWarmCalls() async throws {
        let openGate = AppIntentDependencyOpenGate()
        let historyTask = Task<SwiftDataHistory, Error> {
            await openGate.park()
            return try await SwiftDataHistory.open(
                configuration: HistoryConfiguration(persistence: .memory)
            )
        }
        let manager = AppDependencyManager()
        let resolve = AppIntentDependencyRegistration.register(
            in: manager
        ) {
            let history = try await openGate.awaitHistory(historyTask)
            return AppIntentHistoryIngress(
                facade: history.makeAppIntentsHistoryFacade(),
                onCommittedRemoval: { _ in }
            )
        }

        // Logical cold path: registration happens after the sole real-store
        // open task exists but before its gate is released. The first
        // resolution enters the async provider and waits on that exact task;
        // no second History/store is constructed.
        let firstResolution = Task<AppIntentHistoryIngress, Error> {
            try await resolve()
        }
        await openGate.waitUntilParked()
        await openGate.waitUntilProviderIsWaiting()
        await openGate.release()
        let coldFacade = try await firstResolution.value
        let history = try await historyTask.value

        do {
            _ = try await coldFacade.read(.recent(limit: 1))
            Issue.record("expected the ungranted App Intents connection to be denied")
        } catch let failure as ExternalFailure {
            guard case .unauthorized(let capability, _) = failure else {
                Issue.record("expected unauthorized, got \(failure)")
                return
            }
            #expect(capability == .browse)
        }

        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("app-intent-dependency".utf8)
            )],
            origin: CopyOriginObservation(
                sourceApplication: "ClipyIntegrationTests",
                lineageHint: nil
            ),
            observedAt: Date(timeIntervalSinceReferenceDate: 911_000_200)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let inserted) = commit.outcome else {
            Issue.record("expected inserted History item")
            return
        }

        let connections = try await history.connections()
        let appIntentsConnection = try #require(connections.first)
        try await history.grantCapability(
            .browse,
            to: appIntentsConnection.id
        )

        // Warm: resolving the same registered provider again observes the
        // later durable grant through the retained facade/store graph.
        let warmFacade = try await resolve()
        guard case .page(let page) = try await warmFacade.read(.recent(limit: 1)) else {
            Issue.record("expected a recent page")
            return
        }
        #expect(page.rows.map(\.row.item.id) == [inserted.id])
    }

    @Test("startup failures become a content-free retryable dependency error")
    func registeredProviderMapsStartupFailureToStoreLocked() async throws {
        let manager = AppDependencyManager()
        let resolve = AppIntentDependencyRegistration.register(
            in: manager
        ) { () async throws -> AppIntentHistoryIngress in
            throw HistoryFailure.persistence(.openStore)
        }

        do {
            _ = try await resolve()
            Issue.record("expected dependency resolution to fail")
        } catch let failure as ExternalFailure {
            #expect(failure == .temporarilyUnavailable(.storeLocked))
        }
    }
}

/// One deterministic suspension point before the real in-memory store open.
/// Exactly one task parks and one test waiter observes it; there is no timer,
/// sleep, polling loop, fake persistence implementation, or second writer.
private actor AppIntentDependencyOpenGate {
    private var isParked = false
    private var isProviderWaiting = false
    private var isReleased = false
    private var parkedWaiter: CheckedContinuation<Void, Never>?
    private var providerWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func park() async {
        isParked = true
        parkedWaiter?.resume()
        parkedWaiter = nil
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilParked() async {
        guard !isParked else { return }
        await withCheckedContinuation { continuation in
            parkedWaiter = continuation
        }
    }

    /// Records provider entry, then awaits the exact task that owns the real
    /// store open. Because this actor cannot admit `release()` until the
    /// method reaches `task.value` and suspends, a resumed test waiter knows
    /// the provider really is waiting on that task before releasing startup.
    func awaitHistory(
        _ task: Task<SwiftDataHistory, Error>
    ) async throws -> SwiftDataHistory {
        isProviderWaiting = true
        providerWaiter?.resume()
        providerWaiter = nil
        return try await task.value
    }

    func waitUntilProviderIsWaiting() async {
        guard !isProviderWaiting else { return }
        await withCheckedContinuation { continuation in
            providerWaiter = continuation
        }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
