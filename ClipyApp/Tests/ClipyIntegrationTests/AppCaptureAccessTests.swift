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
        reducer.pause()
        reducer.updateSystemBehavior(.denied)
        reducer.recordReadFailure()

        #expect(reducer.state == .userPaused)
        #expect(reducer.state.recovery == .resume)

        reducer.resume()
        #expect(reducer.state == .readFailure)
        #expect(reducer.state.recovery == .retry)

        reducer.retry(systemBehavior: .allowed)
        #expect(reducer.state == .allowed)
        #expect(reducer.state.recovery == nil)
    }

    @Test("the product Pause window is exactly five minutes")
    func standardPauseDurationIsFiveMinutes() {
        #expect(CapturePausePolicy.standardDuration == .seconds(300))
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

    @Test("remaining non-allowed postures stay stopped until an allowed Retry")
    @MainActor
    func remainingAccessMatrixIsFailClosedAndRecoveryIsExact() async throws {
        let cases: [(
            behavior: PasteboardAccessBehavior,
            state: CaptureAccessState,
            label: String
        )] = [
            (.systemDefault, .systemDefault, "system-default"),
            (.ask, .ask, "ask"),
            (.unavailable, .readFailure, "read-failure"),
        ]

        for testCase in cases {
            let history = try await ComposedSupport.openMemoryHistory()
            let pasteboard = ComposedSupport.makePasteboard()
            pasteboard.clearContents()
            pasteboard.setString(
                "must-not-capture-\(testCase.label)",
                forType: .string
            )
            let accessBehavior = Mutex(testCase.behavior)
            let composition = AppComposition.makeForTesting(
                history: history,
                adapter: PasteboardAdapter(pasteboard: pasteboard),
                observerPollInterval: 0.02,
                captureAccessBehaviorProvider: {
                    accessBehavior.withLock { $0 }
                }
            )

            #expect(composition.captureAccessState == testCase.state)
            #expect(composition.captureAccessState.recovery == .retry)
            #expect(!composition.isCaptureObservationActiveForTesting)

            // A non-allowed posture cannot be converted into the user-owned
            // Pause state, and repeating the same system fact cannot promote
            // capture or consume the staged generation (CLIP-1 / Card 5A).
            composition.pauseCapture()
            composition.retryCaptureAccess()
            #expect(composition.captureAccessState == testCase.state)
            #expect(!composition.isCaptureObservationActiveForTesting)
            var page = try await history.browse(
                HistoryBrowseRequest(kind: .recent, limit: 10)
            )
            #expect(page.rows.isEmpty)

            accessBehavior.withLock { $0 = .allowed }
            composition.retryCaptureAccess()
            #expect(composition.captureAccessState == .allowed)
            #expect(composition.isCaptureObservationActiveForTesting)
            #expect(await Self.waitForRows(1, in: history))
            page = try await history.browse(
                HistoryBrowseRequest(kind: .recent, limit: 10)
            )
            #expect(
                page.rows.map(\.title)
                    == ["must-not-capture-\(testCase.label)"]
            )
            composition.stop()
        }
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
        composition.pauseCapture()
        pasteboard.clearContents()
        pasteboard.setString("copied-while-paused", forType: .string)
        composition.resumeCapture()

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

    @Test("timed Resume baselines paused generations and captures the next copy")
    @MainActor
    func timedResumeExcludesPausedValuesAndCapturesTheNextCopy() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let deadlineSleep = ControlledPauseDeadlineSleep()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("before-timed-pause", forType: .string)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            observerPollInterval: 0.02,
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed },
            capturePauseSleep: { duration in
                try await deadlineSleep.sleep(for: duration)
            }
        )
        defer { composition.stop() }
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)

        #expect(await Self.waitForRows(1, in: history))
        composition.pauseCapture()
        #expect(appDelegate.captureAccessState == .userPaused)
        pasteboard.clearContents()
        pasteboard.setString("copied-during-timed-pause", forType: .string)

        try #require(await ComposedSupport.waitFor {
            deadlineSleep.startedCount == 1
        })
        let deadline = try #require(composition.capturePauseTaskForTesting)
        deadlineSleep.expire(0)
        await deadline.value
        #expect(appDelegate.captureAccessState == .allowed)
        #expect(!composition.hasCapturePauseDeadlineForTesting)
        var page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title) == ["before-timed-pause"])

        pasteboard.clearContents()
        pasteboard.setString("copied-after-timed-resume", forType: .string)
        #expect(await Self.waitForRows(2, in: history))
        page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title).contains("copied-after-timed-resume"))
        #expect(!page.rows.map(\.title).contains("copied-during-timed-pause"))
    }

    @Test("timed Resume rechecks every non-allowed posture")
    @MainActor
    func timedResumeRechecksNonAllowedAccess() async throws {
        let cases: [(PasteboardAccessBehavior, CaptureAccessState, String)] = [
            (.denied, .denied, "denied"),
            (.ask, .ask, "ask"),
            (.unavailable, .readFailure, "unavailable"),
        ]

        for (behavior, expectedState, label) in cases {
            let history = try await ComposedSupport.openMemoryHistory()
            let deadlineSleep = ControlledPauseDeadlineSleep()
            let pasteboard = ComposedSupport.makePasteboard()
            pasteboard.clearContents()
            pasteboard.setString("before-timed-\(label)", forType: .string)
            let accessBehavior = Mutex(PasteboardAccessBehavior.allowed)
            let composition = AppComposition.makeForTesting(
                history: history,
                adapter: PasteboardAdapter(pasteboard: pasteboard),
                observerPollInterval: 0.02,
                initialCaptureAccessBehavior: .allowed,
                captureAccessBehaviorProvider: {
                    accessBehavior.withLock { $0 }
                },
                capturePauseSleep: { duration in
                    try await deadlineSleep.sleep(for: duration)
                }
            )
            defer { composition.stop() }
            let appDelegate = AppDelegate()
            appDelegate.installCompositionForTesting(composition)

            #expect(await Self.waitForRows(1, in: history))
            composition.pauseCapture()
            accessBehavior.withLock { $0 = behavior }
            pasteboard.clearContents()
            pasteboard.setString(
                "must-not-capture-after-\(label)-expiry",
                forType: .string
            )

            try #require(await ComposedSupport.waitFor {
                deadlineSleep.startedCount == 1
            })
            let deadline = try #require(composition.capturePauseTaskForTesting)
            deadlineSleep.expire(0)
            await deadline.value
            #expect(appDelegate.captureAccessState == expectedState)
            #expect(!composition.hasCapturePauseDeadlineForTesting)
            #expect(!composition.isCaptureObservationActiveForTesting)
            let page = try await history.browse(
                HistoryBrowseRequest(kind: .recent, limit: 10)
            )
            #expect(page.rows.map(\.title) == ["before-timed-\(label)"])
        }
    }

    @Test("stopping the composition cancels its Pause deadline")
    @MainActor
    func stopCancelsTimedResume() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let deadlineSleep = ControlledPauseDeadlineSleep()
        let pasteboard = ComposedSupport.makePasteboard()
        let accessReads = Mutex(0)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: {
                accessReads.withLock { count in
                    count += 1
                    return .allowed
                }
            },
            capturePauseSleep: { duration in
                try await deadlineSleep.sleep(for: duration)
            }
        )
        defer { composition.stop() }

        composition.pauseCapture()
        #expect(composition.captureAccessState == .userPaused)
        #expect(composition.hasCapturePauseDeadlineForTesting)
        try #require(await ComposedSupport.waitFor {
            deadlineSleep.startedCount == 1
        })
        let deadline = try #require(composition.capturePauseTaskForTesting)
        composition.stop()
        let readsAfterStop = accessReads.withLock { $0 }
        #expect(deadline.isCancelled)
        deadlineSleep.expire(0)
        await deadline.value

        #expect(composition.captureAccessState == .userPaused)
        #expect(!composition.hasCapturePauseDeadlineForTesting)
        #expect(accessReads.withLock { $0 } == readsAfterStop)
    }

    @Test("manual Resume cancels the outstanding Pause deadline")
    @MainActor
    func manualResumeCancelsTimedResume() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let deadlineSleep = ControlledPauseDeadlineSleep()
        let pasteboard = ComposedSupport.makePasteboard()
        let accessReads = Mutex(0)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: {
                accessReads.withLock { count in
                    count += 1
                    return .allowed
                }
            },
            capturePauseSleep: { duration in
                try await deadlineSleep.sleep(for: duration)
            }
        )
        defer { composition.stop() }

        composition.pauseCapture()
        #expect(composition.hasCapturePauseDeadlineForTesting)
        try #require(await ComposedSupport.waitFor {
            deadlineSleep.startedCount == 1
        })
        let deadline = try #require(composition.capturePauseTaskForTesting)
        composition.resumeCapture()
        #expect(!composition.hasCapturePauseDeadlineForTesting)
        let readsAfterResume = accessReads.withLock { $0 }
        #expect(deadline.isCancelled)
        deadlineSleep.expire(0)
        await deadline.value

        #expect(composition.captureAccessState == .allowed)
        #expect(accessReads.withLock { $0 } == readsAfterResume)
    }

    @Test("a manually resumed Pause cannot end the next Pause")
    @MainActor
    func oldDeadlineCannotResumeANewerPause() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let deadlineSleep = ControlledPauseDeadlineSleep()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(
                pasteboard: ComposedSupport.makePasteboard()
            ),
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed },
            capturePauseSleep: { duration in
                try await deadlineSleep.sleep(for: duration)
            }
        )
        defer { composition.stop() }

        composition.pauseCapture()
        try #require(await ComposedSupport.waitFor {
            deadlineSleep.startedCount == 1
        })
        let oldDeadline = try #require(composition.capturePauseTaskForTesting)
        composition.resumeCapture()
        composition.pauseCapture()
        try #require(await ComposedSupport.waitFor {
            deadlineSleep.startedCount == 2
        })
        let newDeadline = try #require(composition.capturePauseTaskForTesting)
        #expect(oldDeadline.isCancelled)

        // If manual Resume only cleared the old slot without cancelling its
        // task, expiring deadline 0 here would resume the newer Pause.
        deadlineSleep.expire(0)
        await oldDeadline.value
        #expect(composition.captureAccessState == .userPaused)
        #expect(composition.hasCapturePauseDeadlineForTesting)

        deadlineSleep.expire(1)
        await newDeadline.value
        #expect(composition.captureAccessState == .allowed)
        #expect(!composition.hasCapturePauseDeadlineForTesting)
    }

    @Test("the real status-item button exposes Pause and Resume presentation")
    @MainActor
    func hostedStatusItemPresentationTracksCapturePause() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(
                pasteboard: ComposedSupport.makePasteboard()
            ),
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed }
        )
        defer { composition.stop() }
        let appDelegate = AppDelegate()
        appDelegate.installStatusItemForTesting()
        defer { appDelegate.removeStatusItemForTesting() }
        appDelegate.installCompositionForTesting(composition)

        #expect(appDelegate.statusItemAccessibilityLabelForTesting == "Clipy")
        #expect(appDelegate.statusItemHasImageForTesting)
        #expect(
            appDelegate.statusItemSymbolNameForTesting == "list.clipboard"
        )
        composition.pauseCapture()
        #expect(appDelegate.captureAccessState == .userPaused)
        #expect(
            appDelegate.statusItemAccessibilityLabelForTesting
                == "Clipy, clipboard monitoring paused"
        )
        #expect(appDelegate.statusItemHasImageForTesting)
        #expect(appDelegate.statusItemSymbolNameForTesting == "pause.circle")

        composition.resumeCapture()
        #expect(appDelegate.captureAccessState == .allowed)
        #expect(appDelegate.statusItemAccessibilityLabelForTesting == "Clipy")
        #expect(appDelegate.statusItemHasImageForTesting)
        #expect(
            appDelegate.statusItemSymbolNameForTesting == "list.clipboard"
        )
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

/// A deterministic substitute for only the deadline's suspension. Each
/// invocation parks independently and deliberately ignores cancellation.
/// Releasing a retired invocation exercises the production task's check
/// after sleep returns, rather than exiting early through a throwing sleep.
@MainActor
private final class ControlledPauseDeadlineSleep {
    private var nextID = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    private(set) var startedCount = 0

    func sleep(for duration: Duration) async throws {
        _ = duration
        let id = nextID
        nextID += 1
        await withCheckedContinuation { continuation in
            continuations[id] = continuation
            startedCount += 1
        }
    }

    func expire(_ id: Int) {
        continuations.removeValue(forKey: id)?.resume()
    }
}
