import AppKit
import Foundation
import PasteboardAdapter
import QuartzCore
import Testing
@testable import ClipyApp

/// Measures the production window owner and its first visible, laid-out
/// AppKit display-link callback. Registration, its first callback and later
/// layout callbacks are reported separately. These are neither first visible
/// pixels nor hardware-input/store-open measurements; physical five-frame
/// response remains unproved by this same-process observation.
@Suite("Native panel response measurements", .serialized)
@MainActor
struct NativePanelResponseMeasurementTests {
    @Test
    func coldWarmRetargetAndContentFitReachAVisibleLayout() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        for text in ["native-response-one", "native-response-two"] {
            _ = try await history.perform(.capture(ComposedSupport.textCapture(
                text, observedAt: Date(), source: nil
            )))
        }
        let page = try await history.browse(.init(kind: .recent, limit: 2))
        let first = try #require(page.rows.first).item
        let second = try #require(page.rows.last).item
        try #require(first != second)
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: ComposedSupport.makePasteboard()),
            observerPollInterval: 60,
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed }
        )
        let owner = AppDelegate()
        owner.installCompositionForTesting(composition)
        let probe = NativePanelDisplayTickProbe()
        let previewProbe = NativePanelDisplayTickProbe()
        defer {
            probe.stop()
            previewProbe.stop()
            owner.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }

        let cold = try await probe.measure {
            owner.openPanelForTesting()
            return try #require(owner.panelForTesting)
        }
        try #require(cold).report("cold-window-open")
        let panel = try #require(owner.panelForTesting)
        try #require(await ComposedSupport.waitFor { composition.viewState.hasAuthoritativeFirstPage })
        owner.closePanel()
        let warm = try await probe.measure(window: panel) {
            owner.openPanelForTesting()
            return panel
        }
        try #require(warm).report("warm-window-open")
        try #require(await ComposedSupport.waitFor { composition.viewState.hasAuthoritativeFirstPage })

        owner.previewState.isAutoOpenPreferenceEnabled = false
        owner.previewState.handleSelectionChange(first, isExplicit: true)
        let previewShow = try await previewProbe.measure {
            owner.previewState.togglePreview(for: first)
            return try #require(owner.floatingPreviewPanelForTesting)
        }
        try #require(previewShow).report("unprepared-preview-first-show")
        let preview = try #require(panel.childWindows?.compactMap { $0 as? FloatingPreviewPanel }.first)
        let retarget = try await previewProbe.measure(window: preview, action: {
            owner.previewState.handleSelectionChange(second, isExplicit: true)
            return preview
        }, isReady: {
            owner.previewState.previewedItem == second && preview.parent === panel
        })
        try #require(retarget).report("preview-retarget")
        #expect(preview.isPresented)
        #expect(owner.previewState.previewedItem == second)

        let input = PanelContentFit.Input(prefersFullHeight: true)
        let expectedHeight = min(
            PanelContentFit.clampedHeight(PanelContentFit.idealHeight(input),
                                          ceiling: PanelGeometry.persistedSize(from: .standard).height),
            panel.screen?.visibleFrame.height ?? .greatestFiniteMagnitude
        )
        let fit = try await probe.measure(window: panel, action: {
            owner.panelContentFitDidChange(input)
            return panel
        }, isReady: { panel.frame.height == expectedHeight })
        try #require(fit).report("content-fit")
        #expect(preview.frame.maxY == panel.frame.maxY)

        probe.stop()
        previewProbe.stop()
        owner.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(panel.contentView == nil)
        #expect(preview.contentView == nil)
        owner.preparePanelWindowsForTesting()
        #expect(owner.panelForTesting == nil)
        #expect(owner.floatingPreviewPanelForTesting == nil)

        // A second disposable graph measures the production preparation
        // path independently of the genuinely unprepared cold window above.
        let preparedComposition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: ComposedSupport.makePasteboard()),
            observerPollInterval: 60,
            initialCaptureAccessBehavior: .allowed,
            captureAccessBehaviorProvider: { .allowed }
        )
        let preparedOwner = AppDelegate()
        preparedOwner.installCompositionForTesting(preparedComposition)
        let preparedProbe = NativePanelDisplayTickProbe()
        defer {
            preparedProbe.stop()
            preparedOwner.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }
        let clock = ContinuousClock()
        let preparationStarted = clock.now
        preparedOwner.preparePanelWindowsForTesting()
        let preparationMilliseconds = NativePanelDisplayTickProbe.milliseconds(preparationStarted.duration(to: clock.now))
        print(String(format: "NATIVE_PANEL_SETUP hidden_hosting_setup_ms=%.3f explicit_layout=0 history_activation=0 preview_target=0",
                     preparationMilliseconds))
        let preparedPanel = try #require(preparedOwner.panelForTesting)
        let preparedPreview = try #require(preparedOwner.floatingPreviewPanelForTesting)
        #expect(!preparedPanel.isPresented && !preparedPanel.isVisible)
        #expect(!preparedPreview.isPresented && !preparedPreview.isVisible)
        #expect(!preparedComposition.viewState.isLoadingFirstPage)
        #expect(!preparedComposition.viewState.hasAuthoritativeFirstPage)
        #expect(preparedComposition.viewState.rows.isEmpty)
        #expect(preparedOwner.panelSurfaceState?.isSessionActive == false)
        #expect(preparedOwner.floatingPreviewLoader == nil)
        let preparedFirst = try await preparedProbe.measure(window: preparedPanel) {
            preparedOwner.openPanelForTesting()
            return preparedPanel
        }
        try #require(preparedFirst).report("first-summon-after-hidden-window-setup")
        preparedOwner.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(preparedPanel.contentView == nil)
        #expect(preparedPreview.contentView == nil)
    }
}

private struct NativePanelResponseSample {
    let callMilliseconds: Double
    let visibleLayoutMilliseconds: Double
    let callbackTicks: Int
    let frameIntervals: Double
    let framesPerSecond: Double
    let maximumFramesPerSecond: Int
    let motionLevel: Int
    let registrationMilliseconds: Double
    let registrationPosition: String
    let firstCallbackMilliseconds: Double
    let registrationFirstCallbackMilliseconds: Double
    let linkHadTickBeforeAction: Bool

    func report(_ operation: String) {
        print(String(
            format: "NATIVE_PANEL_RESPONSE operation=%@ main_call_ms=%.3f registration_ms=%.3f registration=%@ link_had_tick_before_action=%d first_callback_ms=%.3f registration_first_callback_ms=%.3f first_observed_visible_layout_ms=%.3f layout_after_first_callback_ms=%.3f callback_ticks=%d elapsed_frame_intervals=%.2f display_fps=%.1f maximum_fps=%d motion_level=%d scope=AppKit_callback_not_first_pixels",
            operation, callMilliseconds, registrationMilliseconds, registrationPosition,
            linkHadTickBeforeAction ? 1 : 0, firstCallbackMilliseconds, registrationFirstCallbackMilliseconds,
            visibleLayoutMilliseconds, visibleLayoutMilliseconds - firstCallbackMilliseconds, callbackTicks,
            frameIntervals, framesPerSecond, maximumFramesPerSecond, motionLevel
        ))
    }
}

/// This one measurement owns its real window display link, continuation and
/// timeout. The main window's existing link stays attached across cold/warm/fit
/// operations; the visible preview has its own link for show/retarget. Every
/// timeout and test cleanup invalidates the link and releases its target.
@MainActor
private final class NativePanelDisplayTickProbe: NSObject {
    private var link: CADisplayLink?
    private var timeout: Task<Void, Never>?
    private weak var window: NSWindow?
    private var continuation: CheckedContinuation<NativePanelResponseSample?, Never>?
    private var startedAt: ContinuousClock.Instant?
    private var callMilliseconds = 0.0
    private var callbackTicks = 0
    private var isReady: (() -> Bool)?
    private var registeredAt: ContinuousClock.Instant?
    private var registrationFirstCallbackMilliseconds: Double?
    private var firstCallbackMilliseconds: Double?
    private var registrationMilliseconds = 0.0
    private var registrationPosition = "after-action"
    private var linkHadTickBeforeAction = false

    func measure(
        window knownWindow: NSWindow? = nil,
        action: () throws -> NSWindow,
        isReady: @escaping () -> Bool = { true }
    ) async throws -> NativePanelResponseSample? {
        let clock = ContinuousClock()
        var registrationMilliseconds = 0.0
        var registrationPosition = "after-action"
        if let knownWindow {
            let wasAttached = window === knownWindow && link != nil
            registrationMilliseconds = attach(to: knownWindow)
            registrationPosition = wasAttached ? "reused" : "before-action"
        }
        let linkHadTickBeforeAction = registrationFirstCallbackMilliseconds != nil
        let startedAt = clock.now
        let window = try action()
        let callMilliseconds = Self.milliseconds(startedAt.duration(to: clock.now))
        if self.window !== window || link == nil {
            registrationMilliseconds = attach(to: window)
            registrationPosition = "after-action"
        }
        return await withCheckedContinuation { continuation in
            self.window = window
            self.startedAt = startedAt
            self.callMilliseconds = callMilliseconds
            self.callbackTicks = 0
            self.firstCallbackMilliseconds = nil
            self.registrationMilliseconds = registrationMilliseconds
            self.registrationPosition = registrationPosition
            self.linkHadTickBeforeAction = linkHadTickBeforeAction
            self.isReady = isReady
            self.continuation = continuation
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                self?.stop()
            }
        }
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        let now = ContinuousClock().now
        if registrationFirstCallbackMilliseconds == nil, let registeredAt {
            registrationFirstCallbackMilliseconds = Self.milliseconds(registeredAt.duration(to: now))
        }
        guard let startedAt else { return }
        callbackTicks += 1
        let milliseconds = Self.milliseconds(startedAt.duration(to: now))
        if firstCallbackMilliseconds == nil { firstCallbackMilliseconds = milliseconds }
        guard let window, let content = window.contentView,
              window.isVisible, window.alphaValue > 0,
              content.window === window, !content.needsLayout,
              content.bounds.size == window.contentRect(forFrameRect: window.frame).size,
              isReady?() == true
        else { return }
        let interval = link.targetTimestamp - link.timestamp
        finish(NativePanelResponseSample(
            callMilliseconds: callMilliseconds,
            visibleLayoutMilliseconds: milliseconds,
            callbackTicks: callbackTicks,
            frameIntervals: interval > 0 ? milliseconds / (interval * 1_000) : 0,
            framesPerSecond: interval > 0 ? 1 / interval : 0,
            maximumFramesPerSecond: window.screen?.maximumFramesPerSecond ?? 0,
            motionLevel: AppMotionSettings.load(from: .standard).rawValue,
            registrationMilliseconds: registrationMilliseconds,
            registrationPosition: registrationPosition,
            firstCallbackMilliseconds: firstCallbackMilliseconds ?? milliseconds,
            registrationFirstCallbackMilliseconds: registrationFirstCallbackMilliseconds ?? 0,
            linkHadTickBeforeAction: linkHadTickBeforeAction
        ))
    }

    private func attach(to window: NSWindow) -> Double {
        guard self.window !== window || link == nil else { return 0 }
        link?.invalidate()
        let clock = ContinuousClock()
        let startedAt = clock.now
        self.window = window
        registeredAt = startedAt
        registrationFirstCallbackMilliseconds = nil
        let link = window.displayLink(target: self, selector: #selector(displayTick(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
        return Self.milliseconds(startedAt.duration(to: clock.now))
    }

    func stop() {
        finish(nil)
        link?.invalidate()
        link = nil
        window = nil
        registeredAt = nil
        registrationFirstCallbackMilliseconds = nil
    }

    private func finish(_ sample: NativePanelResponseSample?) {
        timeout?.cancel()
        timeout = nil
        isReady = nil
        startedAt = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: sample)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
