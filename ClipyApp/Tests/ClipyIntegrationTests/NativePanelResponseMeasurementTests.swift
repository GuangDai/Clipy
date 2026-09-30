import AppKit
import Foundation
import PasteboardAdapter
import QuartzCore
import Testing
@testable import ClipyApp

/// Measures the production window owner and its first visible, laid-out
/// AppKit display-link callback. This is not a WindowServer pixel, hardware
/// input or store-open measurement; the refresh interval is also reported.
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
        defer {
            probe.stop()
            let preview = owner.panelForTesting?.childWindows?.compactMap { $0 as? FloatingPreviewPanel }.first
            owner.closePanel()
            composition.stop()
            // The normal app reuses its hosting trees for the process. This
            // disposable owner releases those roots after the measurement.
            preview?.contentView = nil
            owner.panelForTesting?.contentView = nil
        }

        let cold = try await probe.measure {
            owner.openPanelForTesting()
            return try #require(owner.panelForTesting)
        }
        try #require(cold).report("cold-window-open")
        let panel = try #require(owner.panelForTesting)
        try #require(await ComposedSupport.waitFor { composition.viewState.hasAuthoritativeFirstPage })
        owner.closePanel()
        let warm = try await probe.measure {
            owner.openPanelForTesting()
            return panel
        }
        try #require(warm).report("warm-window-open")
        try #require(await ComposedSupport.waitFor { composition.viewState.hasAuthoritativeFirstPage })

        owner.previewState.isAutoOpenPreferenceEnabled = false
        owner.previewState.handleSelectionChange(first, isExplicit: true)
        owner.previewState.togglePreview(for: first)
        let preview = try #require(panel.childWindows?.compactMap { $0 as? FloatingPreviewPanel }.first)
        let retarget = try await probe.measure(action: {
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
        let fit = try await probe.measure(action: {
            owner.panelContentFitDidChange(input)
            return panel
        }, isReady: { panel.frame.height == expectedHeight })
        try #require(fit).report("content-fit")
        #expect(preview.frame.maxY == panel.frame.maxY)
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

    func report(_ operation: String) {
        print(String(
            format: "NATIVE_PANEL_RESPONSE operation=%@ main_call_ms=%.3f first_visible_layout_ms=%.3f callback_ticks=%d elapsed_frame_intervals=%.2f display_fps=%.1f maximum_fps=%d motion_level=%d scope=AppKit_not_WindowServer",
            operation, callMilliseconds, visibleLayoutMilliseconds, callbackTicks,
            frameIntervals, framesPerSecond, maximumFramesPerSecond, motionLevel
        ))
    }
}

/// This one measurement owns its real window display link, continuation and
/// timeout. Every success, timeout and test cleanup invalidates the link and
/// releases its target; no measurement runner or product timer is installed.
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

    func measure(
        action: () throws -> NSWindow,
        isReady: @escaping () -> Bool = { true }
    ) async throws -> NativePanelResponseSample? {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let window = try action()
        let callMilliseconds = Self.milliseconds(startedAt.duration(to: clock.now))
        return await withCheckedContinuation { continuation in
            self.window = window
            self.startedAt = startedAt
            self.callMilliseconds = callMilliseconds
            self.callbackTicks = 0
            self.isReady = isReady
            self.continuation = continuation
            let link = window.displayLink(target: self, selector: #selector(displayTick(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                self?.stop()
            }
        }
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        callbackTicks += 1
        guard let window, let content = window.contentView, let startedAt,
              window.isVisible, window.alphaValue > 0,
              content.window === window, !content.needsLayout,
              content.bounds.size == window.contentRect(forFrameRect: window.frame).size,
              isReady?() == true
        else { return }
        let elapsed = startedAt.duration(to: ContinuousClock().now)
        let milliseconds = Self.milliseconds(elapsed)
        let interval = link.targetTimestamp - link.timestamp
        finish(NativePanelResponseSample(
            callMilliseconds: callMilliseconds,
            visibleLayoutMilliseconds: milliseconds,
            callbackTicks: callbackTicks,
            frameIntervals: interval > 0 ? milliseconds / (interval * 1_000) : 0,
            framesPerSecond: interval > 0 ? 1 / interval : 0,
            maximumFramesPerSecond: window.screen?.maximumFramesPerSecond ?? 0,
            motionLevel: AppMotionSettings.load(from: .standard).rawValue
        ))
    }

    func stop() { finish(nil) }

    private func finish(_ sample: NativePanelResponseSample?) {
        link?.invalidate()
        link = nil
        timeout?.cancel()
        timeout = nil
        window = nil
        isReady = nil
        startedAt = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: sample)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
