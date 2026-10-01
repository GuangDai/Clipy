@testable import ContentPreview
import Foundation
import Testing

#if DEBUG
@Suite("Preview source and waiter admission", .serialized)
struct PreviewAdmissionTests {
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
    )!

    @Test(arguments: [false, true])
    func queuedSourcesShareTheNativeBudgetAndCancellationReleasesIt(includeSibling: Bool) async throws {
        let renderer = ContentPreview()
        let gate = PreviewAdmissionGate()
        let maximumSourceBytes = 64 * 1_048_576
        let representations: [PreviewRepresentation]
        if includeSibling {
            representations = [
                PreviewRepresentation(typeIdentifier: "public.png", bytes: Self.png),
                PreviewRepresentation(typeIdentifier: "opaque.sibling",
                                      bytes: Data(repeating: 0, count: maximumSourceBytes - Self.png.count)),
            ]
        } else {
            representations = [PreviewRepresentation(typeIdentifier: "public.png",
                bytes: Data(repeating: 0, count: maximumSourceBytes))]
        }
        let first = ContentPreviewDebugInstrumentation.$renderDidStart.withValue({ await gate.park() }) {
            Task { await renderer.renderHistoryPane(representations) }
        }
        let didStart = await waitUntil { await gate.isParked }
        if !didStart {
            await gate.resume()
            first.cancel()
            _ = await first.value
            try #require(didStart)
            return
        }
        let second = Task { await renderer.renderHistoryPane(representations) }
        let didQueue = await waitUntil { await renderer.debugSnapshot().queuedRasterJobs == 1 }
        if !didQueue {
            second.cancel()
            await gate.resume()
            _ = await first.value
            _ = await second.value
            try #require(didQueue)
            return
        }
        let busy = await renderer.debugSnapshot()
        #expect(busy.retainedSourceBytes == 2 * maximumSourceBytes)
        #expect(await renderer.renderHistoryPane(representations) == .failed(.renderer))

        second.cancel()
        let didReleaseCancelledSource = await waitUntil {
            let snapshot = await renderer.debugSnapshot()
            return snapshot.queuedRasterJobs == 0 && snapshot.retainedSourceBytes == maximumSourceBytes
        }
        // Always release the native operation, including on an assertion
        // failure, so a cancellation regression cannot hang the test lane.
        await gate.resume()
        _ = await first.value
        #expect(await second.value == .failed(.cancelled))
        #expect(didReleaseCancelledSource)
        let settled = await renderer.debugSnapshot()
        #expect(settled.activeJobs == 0)
        #expect(settled.retainedSourceBytes == 0)
        let retry = await renderer.rasterizePNGForDisplay(Self.png)
        guard case .content(.raster(let raster)) = retry else {
            Issue.record("A drained preview budget must admit the same renderer again")
            return
        }
        #expect(raster.width == 1 && raster.height == 1)
    }

    @Test func manyTinySourcesCannotCreateAnUnboundedWaitQueue() async throws {
        let renderer = ContentPreview()
        let gate = PreviewAdmissionGate()
        let first = ContentPreviewDebugInstrumentation.$renderDidStart.withValue({ await gate.park() }) {
            Task { await renderer.rasterizePNGForDisplay(Self.png) }
        }
        let didStart = await waitUntil { await gate.isParked }
        if !didStart {
            await gate.resume()
            first.cancel()
            _ = await first.value
            try #require(didStart)
            return
        }
        let outcomes = PreviewAdmissionOutcomes()
        let requests = (0..<80).map { _ in
            Task {
                let outcome = await renderer.rasterizePNGForDisplay(Self.png)
                await outcomes.record(outcome)
                return outcome
            }
        }
        let rejectedBeforeNativeCompletion = await waitUntil { await outcomes.rendererFailures > 0 }
        let busy = await renderer.debugSnapshot()
        #expect(rejectedBeforeNativeCompletion)
        #expect(busy.queuedRasterJobs > 0 && busy.queuedRasterJobs < requests.count)
        for request in requests { request.cancel() }
        let didDrainQueue = await waitUntil { await renderer.debugSnapshot().queuedRasterJobs == 0 }
        await gate.resume()
        _ = await first.value
        for request in requests { _ = await request.value }
        #expect(didDrainQueue)
        #expect(await renderer.debugSnapshot().retainedSourceBytes == 0)
        guard case .content(.raster) = await renderer.rasterizePNGForDisplay(Self.png) else {
            Issue.record("Queue overflow must remain retryable after admitted work drains")
            return
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return false }
        }
        return await condition()
    }
}

private actor PreviewAdmissionGate {
    private(set) var isParked = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func park() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isParked = true
        }
    }

    func resume() {
        isReleased = true
        continuation?.resume()
        continuation = nil
        isParked = false
    }
}

private actor PreviewAdmissionOutcomes {
    private(set) var rendererFailures = 0

    func record(_ outcome: PreviewOutcome) {
        if outcome == .failed(.renderer) { rendererFailures += 1 }
    }
}
#endif
