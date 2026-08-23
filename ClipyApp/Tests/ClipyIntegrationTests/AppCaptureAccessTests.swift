/// REVIEW Card 5A: pasteboard access is authoritative application state, not
/// an empty-history alias. Pure tests pin the six-state admission policy; the
/// composed tracer uses a real named pasteboard and real in-memory History.
import Foundation
import HistoryCore
import PasteboardAdapter
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
        var accessBehavior = PasteboardAccessBehavior.denied

        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            observerPollInterval: 0.02,
            captureAccessBehaviorProvider: { accessBehavior }
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

        accessBehavior = .allowed
        composition.retryCaptureAccess()
        let captured = await ComposedSupport.waitFor {
            guard let page = try? await history.browse(
                HistoryBrowseRequest(kind: .recent, limit: 10)
            ) else { return false }
            return page.rows.count == 1
        }
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

    @Test("live revocation stops the composed observer")
    @MainActor
    func liveRevocationStopsObservation() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("before-revoke", forType: .string)
        var accessBehavior = PasteboardAccessBehavior.allowed
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            observerPollInterval: 0.02,
            captureAccessBehaviorProvider: { accessBehavior }
        )
        defer { composition.stop() }
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        let initiallyCaptured = await ComposedSupport.waitFor {
            guard let page = try? await history.browse(
                HistoryBrowseRequest(kind: .recent, limit: 10)
            ) else { return false }
            return page.rows.count == 1
        }
        #expect(initiallyCaptured)

        accessBehavior = .denied
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
}
