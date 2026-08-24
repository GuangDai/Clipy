/// PanelLifecycleHostedTests.swift — the bounded hosted Card 14C/14D leaf
/// for the actual floating window and panel-session owners. These tests use
/// the production `FloatingPanel`, `HistoryViewState`, and
/// `HistoryPanelSurfaceState`; the History double only records observation
/// registrations because storage semantics are outside this lifecycle leaf.
///
/// This same-process evidence does not claim WindowServer, Spaces, sleep /
/// wake, fast-user-switching, or cross-process focus behavior.
import AppKit
import HistoryCore
import PasteboardAdapter
import PresentationUI
import Testing
@testable import ClipyApp

@Suite("Hosted panel lifecycle", .serialized)
@MainActor
struct PanelLifecycleHostedTests {

    @Test("focus loss ends one session; reopen starts one replacement observation")
    func focusLossClosesExactlyOnceAndReopenStartsFreshSession() async throws {
        let installed = installedOwner()
        let appDelegate = installed.appDelegate
        let composition = installed.composition
        let history = installed.history
        defer {
            appDelegate.closePanel()
            composition.stop()
        }

        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        let surface = try #require(appDelegate.panelSurfaceState)
        await history.waitForObservationCount(1)

        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == 1)
        #expect(await history.observationCount == 1)

        // `resignKey` is the production outside-click/focus-loss path. The
        // close callback owns both session retirement and view observation
        // cancellation; a duplicate AppKit notification must be a no-op.
        panel.resignKey()
        panel.resignKey()
        await history.waitForTerminationCount(1)

        #expect(!panel.isPresented)
        #expect(!surface.isSessionActive)
        #expect(await history.observationCount == 1)
        #expect(await history.terminationCount == 1)

        appDelegate.openPanelForTesting()
        await history.waitForObservationCount(2)

        // A second activation signal in the same open episode must reuse the
        // active observation. Only close -> reopen creates a new generation.
        composition.viewState.activate()
        #expect(surface.isSessionActive)
        #expect(surface.sessionGeneration == 2)
        #expect(await history.observationCount == 2)

        appDelegate.closePanel()
        appDelegate.closePanel()
        await history.waitForTerminationCount(2)
        #expect(!surface.isSessionActive)
        #expect(await history.terminationCount == 2)
    }

    @Test("an attached NSAlert preserves the panel until the alert ends")
    func modalAlertSuppressesFocusLossClose() async throws {
        let installed = installedOwner()
        let appDelegate = installed.appDelegate
        let composition = installed.composition
        let history = installed.history
        appDelegate.openPanelForTesting()
        let panel = try #require(appDelegate.panelForTesting)
        let surface = try #require(appDelegate.panelSurfaceState)
        await history.waitForObservationCount(1)
        let alert = NSAlert()
        alert.messageText = "Hosted lifecycle alert"
        alert.addButton(withTitle: "OK")
        let alertWindow = alert.window
        defer {
            if panel.attachedSheet === alertWindow {
                panel.endSheet(alertWindow)
            }
            appDelegate.closePanel()
            composition.stop()
        }

        alert.beginSheetModal(for: panel) { _ in }
        #expect(panel.attachedSheet === alertWindow)

        // AppKit transfers key status to a sheet. The production public-API
        // modal predicate must retain the panel while that sheet is attached.
        panel.resignKey()
        #expect(panel.isPresented)
        #expect(surface.isSessionActive)
        #expect(await history.terminationCount == 0)

        panel.endSheet(alertWindow)
        #expect(panel.attachedSheet == nil)
        panel.resignKey()
        await history.waitForTerminationCount(1)
        #expect(!panel.isPresented)
        #expect(!surface.isSessionActive)
        #expect(await history.terminationCount == 1)
    }

    private func installedOwner() -> (
        appDelegate: AppDelegate,
        composition: AppComposition,
        history: LifecycleObservationHistory
    ) {
        let history = LifecycleObservationHistory()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "com.clipy.panel-lifecycle.\(UUID().uuidString)"
            )
        )
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            observerPollInterval: 60,
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed }
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        return (appDelegate, composition, history)
    }
}

/// Records only lifecycle-facing observation registrations. Its streams stay
/// open until the view-state cancels them, so each count is one live panel
/// observation rather than a loop that immediately completes and restarts.
private actor LifecycleObservationHistory: ClipboardHistory {
    private(set) var observationCount = 0
    private(set) var terminationCount = 0
    private var observationContinuations: [
        AsyncThrowingStream<HistoryPage, Error>.Continuation
    ] = []
    private var countWaiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var terminationWaiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func waitForObservationCount(_ target: Int) async {
        guard observationCount < target else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((target, continuation))
        }
    }

    func waitForTerminationCount(_ target: Int) async {
        guard terminationCount < target else { return }
        await withCheckedContinuation { continuation in
            terminationWaiters.append((target, continuation))
        }
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        .unchanged
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        throw CancellationError()
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        observationCount += 1
        let (stream, continuation) =
            AsyncThrowingStream<HistoryPage, Error>.makeStream()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.recordObservationTermination() }
        }
        observationContinuations.append(continuation)

        var remaining: [
            (target: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in countWaiters {
            if waiter.target <= observationCount {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
        return stream
    }

    private func recordObservationTermination() {
        terminationCount += 1
        var remaining: [
            (target: Int, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in terminationWaiters {
            if waiter.target <= terminationCount {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        terminationWaiters = remaining
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        throw HistoryFailure.notFound(id)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        throw HistoryFailure.notFound(id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        nil
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        throw CancellationError()
    }
}
