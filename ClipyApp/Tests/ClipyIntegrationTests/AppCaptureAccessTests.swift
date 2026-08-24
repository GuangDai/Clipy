/// REVIEW Card 5A: pasteboard access is authoritative application state, not
/// an empty-history alias. Pure tests pin the six-state admission policy; the
/// composed tracer uses a real named pasteboard and real in-memory History.
import Foundation
import HistoryCore
import PasteboardAdapter
import Synchronization
import Testing
@testable import ClipyApp

@Suite("App capture access state")
struct AppCaptureAccessTests {
    @Test("only explicit allow admits background polling")
    @MainActor
    func onlyExplicitAllowAdmitsBackgroundPolling() {
        let cases: [(PasteboardAccessBehavior, CaptureAccessState)] = [
            (.systemDefault, .systemDefault),
            (.ask, .ask),
            (.allowed, .allowed),
            (.denied, .denied),
            (.unavailable, .readFailure),
        ]

        for (behavior, expected) in cases {
            let reducer = CaptureAccessReducer(systemBehavior: behavior)
            #expect(reducer.state == expected)
            #expect(
                reducer.state.permitsBackgroundPolling == (expected == .allowed)
            )
            #expect(
                reducer.state.recovery
                    == (expected == .allowed ? nil : .retry)
            )
        }
    }

    @Test("pause wins over system and read-failure changes")
    @MainActor
    func userPauseHasPrecedence() {
        var reducer = CaptureAccessReducer(systemBehavior: .allowed)
        reducer.setUserPaused(true)
        reducer.updateSystemBehavior(.denied)
        reducer.recordReadFailure()

        #expect(reducer.state == .userPaused)
        #expect(reducer.state.recovery == .resume)

        reducer.setUserPaused(false)
        #expect(reducer.state == .readFailure)
        #expect(reducer.state.recovery == .retry)

        reducer.retry(systemBehavior: .allowed)
        #expect(reducer.state == .allowed)
        #expect(reducer.state.recovery == nil)
    }

    @Test("denied startup reads nothing and one recovery observes once")
    @MainActor
    func deniedStartupAndRecoveryAreBounded() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("access-recovery", forType: .string)
        let accessBehavior = Mutex(PasteboardAccessBehavior.denied)

        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            observerPollInterval: 0.02,
            captureAccessBehaviorProvider: {
                accessBehavior.withLock { $0 }
            }
        )
        defer { composition.stop() }
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)

        #expect(appDelegate.captureAccessState == .denied)
        #expect(appDelegate.captureAccessState.recovery == .retry)
        let deniedPage = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(deniedPage.rows.isEmpty)

        accessBehavior.withLock { $0 = .allowed }
        composition.retryCaptureAccess()
        let captured = await Self.waitForRows(1, in: history)
        #expect(captured)
        #expect(appDelegate.captureAccessState == .allowed)

        // An already-running observer accepts repeated recovery/refresh
        // intents without re-freezing the same generation.
        composition.retryCaptureAccess()
        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.count == 1)
        #expect(page.rows.first?.copyCount == 1)

    }

    @Test("user resume baselines pause-period clipboard generations")
    @MainActor
    func userResumeExcludesPausedValuesAndCapturesTheNextCopy() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("before-pause", forType: .string)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            observerPollInterval: 0.02,
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed }
        )
        defer { composition.stop() }

        #expect(await Self.waitForRows(1, in: history))
        composition.setCapturePaused(true)
        pasteboard.clearContents()
        pasteboard.setString("copied-while-paused", forType: .string)
        composition.setCapturePaused(false)

        var page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title) == ["before-pause"])

        pasteboard.clearContents()
        pasteboard.setString("copied-after-resume", forType: .string)
        #expect(await Self.waitForRows(2, in: history))
        page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title).contains("copied-after-resume"))
        #expect(!page.rows.map(\.title).contains("copied-while-paused"))
    }

    @Test("live revocation stops the composed observer")
    @MainActor
    func liveRevocationStopsObservation() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("before-revoke", forType: .string)
        let accessBehavior = Mutex(PasteboardAccessBehavior.allowed)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            observerPollInterval: 0.02,
            captureAccessBehaviorProvider: {
                accessBehavior.withLock { $0 }
            }
        )
        defer { composition.stop() }
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        let initiallyCaptured = await Self.waitForRows(1, in: history)
        #expect(initiallyCaptured)

        accessBehavior.withLock { $0 = .denied }
        pasteboard.clearContents()
        pasteboard.setString("must-not-be-read", forType: .string)
        let revoked = await ComposedSupport.waitFor {
            appDelegate.captureAccessState == .denied
        }
        #expect(revoked)
        let afterRevoke = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(afterRevoke.rows.count == 1)
    }

    @MainActor
    private static func waitForRows(
        _ expectedCount: Int,
        in history: any ClipboardHistory,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let page = try? await history.browse(
                HistoryBrowseRequest(kind: .recent, limit: 10)
            ), page.rows.count == expectedCount {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
