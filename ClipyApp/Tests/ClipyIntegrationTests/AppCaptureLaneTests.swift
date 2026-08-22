/// AppCaptureLaneTests — REVIEW Card 6's bounded app-owner capture lane.
///
/// The seam is the real `AppComposition` entry plus its content-free health
/// snapshot. Durable assertions always read through a real in-memory
/// `SwiftDataHistory`. Test adapters only delay one real boundary operation;
/// every write and read still forwards to that authority.
import AppKit
import Foundation
import HistoryCore
@testable import HistoryStorage
import PasteboardAdapter
import Testing
@testable import ClipyApp

struct AppCaptureLaneTests {

    /// Card 6 discriminator: with A active, B occupies the one pending slot,
    /// and C replaces B. After dismissing that episode, D replaces C and must
    /// surface again. Resuming the real History commit therefore retains
    /// literal A then literal D while proving the task backlog stayed 1 + 1.
    @Test @MainActor
    func activeCaptureKeepsOnlyTheLatestPendingValue() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let history = FirstCaptureSuspendingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        defer { composition.stop() }

        composition.submitCaptureForTesting(Self.capture("A", at: 1))
        await history.waitUntilFirstCaptureIsSuspended()
        #expect(composition.captureHealth.activeCommitCount == 1)
        #expect(composition.captureHealth.activeCaptureBytes == 1)
        #expect(composition.captureHealth.pendingCaptureCount == 0)
        #expect(composition.captureHealth.pendingCaptureBytes == 0)
        #expect(appDelegate.captureHealth.activeCommitCount == 1)
        #expect(appDelegate.captureHealth.activeCaptureBytes == 1)
        #expect(appDelegate.captureHealth.pendingCaptureCount == 0)

        composition.submitCaptureForTesting(Self.capture("B", at: 2))
        #expect(composition.captureHealth.activeCommitCount == 1)
        #expect(composition.captureHealth.pendingCaptureCount == 1)
        #expect(composition.captureHealth.pendingCaptureBytes == 1)
        #expect(composition.captureHealth.replacedCaptureCount == 0)
        #expect(appDelegate.captureHealth.pendingCaptureCount == 1)
        #expect(appDelegate.captureHealth.pendingCaptureBytes == 1)
        #expect(appDelegate.captureHealth.replacedCaptureCount == 0)

        composition.submitCaptureForTesting(Self.capture("C", at: 3))
        #expect(composition.captureHealth.activeCommitCount == 1)
        #expect(composition.captureHealth.pendingCaptureCount == 1)
        #expect(composition.captureHealth.pendingCaptureBytes == 1)
        #expect(composition.captureHealth.replacedCaptureCount == 1)
        #expect(appDelegate.captureHealth.pendingCaptureCount == 1)
        #expect(appDelegate.captureHealth.replacedCaptureCount == 1)
        #expect(
            appDelegate.captureNotice == .replacedCapture(totalReplaced: 1)
        )

        appDelegate.dismissCaptureNotice()
        #expect(appDelegate.captureNotice == nil)

        composition.submitCaptureForTesting(Self.capture("D", at: 4))
        #expect(composition.captureHealth.replacedCaptureCount == 2)
        #expect(appDelegate.captureHealth.replacedCaptureCount == 2)
        #expect(
            appDelegate.captureNotice == .replacedCapture(totalReplaced: 2),
            "a later replacement is a new visible episode after dismiss"
        )

        await history.resumeFirstCapture()
        let drained = await ComposedSupport.waitFor {
            composition.captureHealth.activeCommitCount == 0
                && composition.captureHealth.pendingCaptureCount == 0
        }
        #expect(drained, "Card 6: the bounded lane drains A then latest D")
        #expect(composition.captureHealth.lastFailure == nil)

        let page = try await base.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title) == ["D", "A"])
        #expect(!page.rows.map(\.title).contains("B"))
        #expect(!page.rows.map(\.title).contains("C"))
    }

    /// A capture receipt carries same-commit retention effects back through
    /// the app owner before the next authoritative observation is delivered.
    /// The held pre-commit rows are therefore non-executable during that
    /// delivery gap, then the real storage snapshot repopulates survivors.
    @Test @MainActor
    func captureRetentionReceiptPurgesSurfaceBeforeObservationCatchesUp() async throws {
        let base = try await ComposedSupport.openMemoryHistory(maximumUnpinned: 2)
        _ = try await base.perform(.capture(Self.capture("A", at: 5)))
        _ = try await base.perform(.capture(Self.capture("B", at: 6)))
        let history = PostInitialObservationSuspendingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        defer { composition.stop() }

        composition.viewState.activate()
        let initialPageArrived = await ComposedSupport.waitFor {
            composition.viewState.rows.map(\.title) == ["B", "A"]
        }
        #expect(initialPageArrived)

        composition.submitCaptureForTesting(Self.capture("C", at: 7))
        await history.waitUntilPostInitialObservationIsHeld()
        let drained = await ComposedSupport.waitFor {
            composition.captureHealth.activeCommitCount == 0
        }
        #expect(drained)
        #expect(
            composition.viewState.rows.isEmpty,
            "the destructive receipt retires stale executable rows"
        )

        await history.releasePostInitialObservation()
        let authoritativePageArrived = await ComposedSupport.waitFor {
            composition.viewState.rows.map(\.title) == ["C", "B"]
        }
        #expect(authoritativePageArrived)
    }

    /// A stopped owner drops its pending capture and cancels the active task.
    /// The adapter deliberately completes A non-cooperatively after stop;
    /// A may already have crossed into History, but its late return must not
    /// launch pending B or reactivate the drain.
    @Test @MainActor
    func stopPreventsANonCooperativeCompletionFromDrainingPendingWork() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let history = FirstCaptureSuspendingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )

        composition.submitCaptureForTesting(Self.capture("A", at: 10))
        await history.waitUntilFirstCaptureIsSuspended()
        composition.submitCaptureForTesting(Self.capture("B", at: 11))
        #expect(composition.captureHealth.pendingCaptureCount == 1)

        composition.stop()
        #expect(composition.captureHealth.activeCommitCount == 0)
        #expect(composition.captureHealth.activeCaptureBytes == 0)
        #expect(composition.captureHealth.pendingCaptureCount == 0)
        #expect(composition.captureHealth.pendingCaptureBytes == 0)

        await history.resumeFirstCapture()
        let firstLanded = await Self.waitForRows(1, in: base)
        #expect(firstLanded, "the already-started non-cooperative A may finish")

        // Give the cancelled task a second scheduling turn after its late
        // return. A buggy completion path would now start pending B.
        await Task.yield()
        await Task.yield()
        let page = try await base.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title) == ["A"])
        #expect(composition.captureHealth.activeCommitCount == 0)
        #expect(composition.captureHealth.pendingCaptureCount == 0)
    }

    /// Capacity failures from the real storage path are retained as a typed,
    /// content-free health fact. They are not erased by `try?`, while the
    /// rejected bytes never become durable History state.
    @Test @MainActor
    func capacityFailureIsVisibleInCaptureHealth() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        _ = try await history.perform(.setRetentionPolicies(
            HistoryRetentionPolicies(
                age: nil,
                storage: StorageRetention(maxTotalBytes: 1),
                revisions: nil
            )
        ))
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        defer { composition.stop() }

        composition.submitCaptureForTesting(Self.capture("over budget", at: 20))
        let failed = await ComposedSupport.waitFor {
            composition.captureHealth.activeCommitCount == 0
                && composition.captureHealth.lastFailure
                    == .capacityExceeded(.storageBytes)
        }
        #expect(failed, "Card 6: capacity failure remains typed and visible")
        #expect(
            appDelegate.captureHealth.lastFailure
                == .capacityExceeded(.storageBytes)
        )
        #expect(
            appDelegate.captureNotice
                == .failed(.capacityExceeded(.storageBytes))
        )

        appDelegate.dismissCaptureNotice()
        #expect(appDelegate.captureNotice == nil)

        composition.submitCaptureForTesting(Self.capture("same failure", at: 21))
        let repeatedFailure = await ComposedSupport.waitFor {
            appDelegate.captureNotice
                == .failed(.capacityExceeded(.storageBytes))
        }
        #expect(
            repeatedFailure,
            "the same typed failure on a later capture is a new episode"
        )

        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.isEmpty)
    }

    /// An ENOSPC failure is a recoverable capture-health episode, not a
    /// reason to drain bytes that were already waiting behind the failed
    /// transaction. B is dropped when A fails; only the later, explicit C
    /// observation retries against the same real History authority.
    @Test @MainActor
    func lowDiskFailureDropsPendingUntilANewCaptureExplicitlyRetries() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        _ = try await base.perform(.capture(Self.capture("seed", at: 19)))
        let history = FirstCaptureLowDiskFailingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        let appDelegateHealthSink = composition.onCaptureHealthChanged
        let healthProbe = CaptureHealthProbe()
        composition.onCaptureHealthChanged = { health in
            appDelegateHealthSink?(health)
            healthProbe.receive(health)
        }
        defer { composition.stop() }

        composition.submitCaptureForTesting(Self.capture("A", at: 20))
        await history.waitUntilFirstCaptureIsSuspended()
        composition.submitCaptureForTesting(Self.capture("B", at: 21))
        #expect(composition.captureHealth.pendingCaptureCount == 1)

        await history.failFirstCaptureWithLowDisk()
        await healthProbe.waitForIdle(
            failedCaptureCount: 1,
            lastFailure: .temporarilyUnavailable(.insufficientDiskSpace)
        )

        #expect(composition.captureHealth.pendingCaptureCount == 0)
        #expect(composition.captureHealth.pendingCaptureBytes == 0)
        #expect(await history.captureAttemptCount == 1)
        #expect(
            appDelegate.captureNotice
                == .failed(.temporarilyUnavailable(.insufficientDiskSpace))
        )
        let afterFailure = try await base.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(afterFailure.rows.map(\.title) == ["seed"])

        composition.submitCaptureForTesting(Self.capture("C", at: 22))
        await healthProbe.waitForIdle(
            failedCaptureCount: 1,
            lastFailure: nil
        )

        #expect(await history.captureAttemptCount == 2)
        #expect(appDelegate.captureNotice == nil)
        let afterExplicitRetry = try await base.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(afterExplicitRetry.rows.map(\.title) == ["C", "seed"])
    }

    /// The owner applies its aggregate memory bound before a complete capture
    /// can occupy active or pending storage. A tiny Debug limit exercises the
    /// production checked-admission path without allocating a 128 MiB fixture.
    @Test @MainActor
    func oversizedCaptureDoesNotOccupyEitherLaneSlot() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            captureByteLimit: 4
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        defer { composition.stop() }

        composition.submitCaptureForTesting(Self.capture("12345", at: 22))

        #expect(composition.captureHealth.activeCommitCount == 0)
        #expect(composition.captureHealth.activeCaptureBytes == 0)
        #expect(composition.captureHealth.pendingCaptureCount == 0)
        #expect(composition.captureHealth.pendingCaptureBytes == 0)
        #expect(appDelegate.captureNotice == .failed(.invalidInput))

        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.isEmpty)
    }

    /// A success admitted before a later failure is not that failure's retry.
    /// Its late completion must preserve the newer episode; only a capture
    /// admitted after the episode can prove recovery and clear the banner.
    @Test @MainActor
    func olderSuccessCannotClearANewerFailureEpisode() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let history = FirstCaptureSuspendingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            captureByteLimit: 4
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        defer { composition.stop() }

        composition.submitCaptureForTesting(Self.capture("A", at: 23))
        await history.waitUntilFirstCaptureIsSuspended()
        composition.submitCaptureForTesting(Self.capture("12345", at: 24))
        #expect(appDelegate.captureNotice == .failed(.invalidInput))

        await history.resumeFirstCapture()
        let oldSuccessSettled = await ComposedSupport.waitFor {
            composition.captureHealth.activeCommitCount == 0
        }
        #expect(oldSuccessSettled)
        #expect(composition.captureHealth.lastFailure == .invalidInput)
        #expect(appDelegate.captureNotice == .failed(.invalidInput))

        composition.submitCaptureForTesting(Self.capture("C", at: 25))
        let recovered = await ComposedSupport.waitFor {
            composition.captureHealth.activeCommitCount == 0
                && composition.captureHealth.lastFailure == nil
                && appDelegate.captureNotice == nil
        }
        #expect(recovered, "only a post-failure admitted success proves recovery")

        let page = try await base.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.map(\.title) == ["C", "A"])
    }

    /// Adapter outcomes that cannot become complete Canonical Content are
    /// explicit health episodes, not silent drops and not lane entries.
    @Test @MainActor
    func multiItemClipboardPublishesContentFreeUnsupportedShape() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        let second = NSPasteboardItem()
        #expect(first.setString("first", forType: .string))
        #expect(second.setString("second", forType: .string))
        #expect(pasteboard.writeObjects([first, second]))

        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        defer { composition.stop() }

        #expect(
            appDelegate.captureNotice == .failed(.unsupportedClipboardShape)
        )
        #expect(appDelegate.captureHealth.activeCommitCount == 0)
        #expect(appDelegate.captureHealth.pendingCaptureCount == 0)
    }

#if DEBUG
    /// The composition maps the adapter owner's declared-content-unavailable
    /// result to one content-free category and never submits the triggering
    /// observation. The adapter suite separately proves that an actual
    /// all-unavailable provider yields the explicit empty partial; this hosted
    /// test does not need access to that package-only AppKit fixture.
    @Test @MainActor
    func declaredContentUnavailableDispositionPublishesContentFreeFailure() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let unavailableType = NSPasteboard.PasteboardType("private.fixture.html")
        pasteboard.setData(Data("<b>rich</b>".utf8), forType: unavailableType)
        let adapter = PasteboardAdapter(pasteboard: pasteboard)

        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: adapter,
            initialCaptureFailure: .declaredContentUnavailable
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        defer { composition.stop() }

        #expect(
            appDelegate.captureNotice == .failed(.declaredContentUnavailable)
        )
        #expect(appDelegate.captureHealth.activeCommitCount == 0)
        #expect(appDelegate.captureHealth.pendingCaptureCount == 0)

        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.isEmpty)
    }
#endif

    /// The adapter's early concealment outcome is intentionally quiet at the
    /// same production callback seam that surfaces unsupported/unavailable
    /// outcomes. Its empty capture never occupies a lane slot.
    @Test @MainActor
    func concealedAdapterOutcomeDoesNotPublishHealthFailure() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("secret", forType: .string)
        pasteboard.setData(
            Data("marker".utf8),
            forType: NSPasteboard.PasteboardType(
                "org.nspasteboard.ConcealedType"
            )
        )

        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        defer { composition.stop() }

        #expect(appDelegate.captureHealth.failedCaptureCount == 0)
        #expect(appDelegate.captureHealth.activeCommitCount == 0)
        #expect(appDelegate.captureHealth.pendingCaptureCount == 0)
        #expect(appDelegate.captureNotice == nil)
    }

    /// Concealed content is the one intentionally quiet History rejection:
    /// storage still rejects it before fingerprinting, but the app owner does
    /// not mark capture health degraded for the expected privacy decision.
    @Test @MainActor
    func excludedCaptureDoesNotBecomeAHealthFailure() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        defer { composition.stop() }

        composition.submitCaptureForTesting(
            ClipboardCapture(
                representations: [CapturedRepresentation(
                    typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                    bytes: Data("secret".utf8)
                )],
                origin: CopyOriginObservation(
                    sourceApplication: nil,
                    lineageHint: nil
                ),
                observedAt: Date(timeIntervalSinceReferenceDate: 30),
                isConcealed: true
            )
        )
        let settled = await ComposedSupport.waitFor {
            composition.captureHealth.activeCommitCount == 0
        }
        #expect(settled)
        #expect(composition.captureHealth.lastFailure == nil)
        #expect(appDelegate.captureHealth.failedCaptureCount == 0)
        #expect(appDelegate.captureHealth.lastFailure == nil)
        #expect(appDelegate.captureNotice == nil)

        let page = try await history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        )
        #expect(page.rows.isEmpty)
    }

    /// History's invalid-input vocabulary may carry the rejected UTI. The app
    /// owner must collapse it to a content-free category before publishing
    /// health to AppDelegate or retaining a panel notice.
    @Test @MainActor
    func rejectedTypeIdentifierIsRemovedFromPublishedHealth() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        defer { composition.stop() }

        composition.submitCaptureForTesting(
            ClipboardCapture(
                representations: [CapturedRepresentation(
                    typeIdentifier: String(repeating: "private-sensitive-uti", count: 30),
                    bytes: Data("value".utf8)
                )],
                origin: CopyOriginObservation(
                    sourceApplication: nil,
                    lineageHint: nil
                ),
                observedAt: Date(timeIntervalSinceReferenceDate: 31),
                isConcealed: false
            )
        )

        let failed = await ComposedSupport.waitFor {
            appDelegate.captureNotice == .failed(.invalidInput)
        }
        #expect(failed)
        #expect(appDelegate.captureHealth.lastFailure == .invalidInput)
    }

    private static func capture(_ text: String, at timestamp: TimeInterval) -> ClipboardCapture {
        ComposedSupport.textCapture(
            text,
            observedAt: Date(timeIntervalSinceReferenceDate: timestamp),
            source: "com.example.capture-lane"
        )
    }

    private static func waitForRows(
        _ count: Int,
        in history: SwiftDataHistory
    ) async -> Bool {
        for _ in 0..<200 {
            if let page = try? await history.browse(
                HistoryBrowseRequest(kind: .recent, limit: 10)
            ), page.rows.count == count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

/// A one-shot transaction-boundary failure adapter. It parks only the first
/// capture, returns History's public low-disk failure when released, then
/// forwards every later operation and every read to the same real store.
private actor FirstCaptureLowDiskFailingHistory: ClipboardHistory {
    private let base: SwiftDataHistory
    private var captureAttempts = 0
    private var firstCaptureContinuation: CheckedContinuation<Void, Never>?
    private var firstCaptureWaiters: [CheckedContinuation<Void, Never>] = []

    init(base: SwiftDataHistory) {
        self.base = base
    }

    var captureAttemptCount: Int {
        captureAttempts
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        guard case .capture = action else {
            return try await base.perform(action)
        }

        captureAttempts += 1
        guard captureAttempts == 1 else {
            return try await base.perform(action)
        }

        let waiters = firstCaptureWaiters
        firstCaptureWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            firstCaptureContinuation = continuation
        }
        await base.authority.setTransactionFailureInjection(
            .insufficientDiskSpace
        )
        return try await base.perform(action)
    }

    func waitUntilFirstCaptureIsSuspended() async {
        guard captureAttempts == 0 else { return }
        await withCheckedContinuation { continuation in
            firstCaptureWaiters.append(continuation)
        }
    }

    func failFirstCaptureWithLowDisk() {
        let continuation = firstCaptureContinuation
        firstCaptureContinuation = nil
        continuation?.resume()
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        try await base.browse(request)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        await base.observe(request)
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        try await base.details(for: id)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        try await base.pastePayload(for: id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        try await base.thumbnail(for: item, pixels: pixels)
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        try await base.retentionConfiguration()
    }
}

/// Deterministic observation of AppComposition's existing content-free push
/// seam. A waiter first checks the latest snapshot, so it cannot miss a
/// synchronous transition and needs neither polling nor a timer.
@MainActor
private final class CaptureHealthProbe {
    private var latest = ClipyCaptureHealth.inactive
    private var waiter: (
        failedCaptureCount: Int,
        lastFailure: ClipyCaptureFailure?,
        continuation: CheckedContinuation<Void, Never>
    )?

    func receive(_ health: ClipyCaptureHealth) {
        latest = health
        resumeWaiterIfSatisfied()
    }

    func waitForIdle(
        failedCaptureCount: Int,
        lastFailure: ClipyCaptureFailure?
    ) async {
        if matches(
            failedCaptureCount: failedCaptureCount,
            lastFailure: lastFailure
        ) {
            return
        }
        await withCheckedContinuation { continuation in
            precondition(waiter == nil)
            waiter = (failedCaptureCount, lastFailure, continuation)
        }
    }

    private func resumeWaiterIfSatisfied() {
        guard let waiter,
              matches(
                failedCaptureCount: waiter.failedCaptureCount,
                lastFailure: waiter.lastFailure
              ) else {
            return
        }
        self.waiter = nil
        waiter.continuation.resume()
    }

    private func matches(
        failedCaptureCount: Int,
        lastFailure: ClipyCaptureFailure?
    ) -> Bool {
        latest.activeCommitCount == 0
            && latest.pendingCaptureCount == 0
            && latest.failedCaptureCount == failedCaptureCount
            && latest.lastFailure == lastFailure
    }
}

/// The only History adapter in this suite: pause capture 1 at the process
/// boundary, then forward every operation/read to the same real store. Its
/// detached forward makes capture 1 intentionally non-cooperative with the
/// caller's cancellation so the stop fence is observable deterministically.
private actor FirstCaptureSuspendingHistory: ClipboardHistory {
    private let base: SwiftDataHistory
    private var captureCount = 0
    private var firstCaptureContinuation: CheckedContinuation<Void, Never>?
    private var firstCaptureWaiters: [CheckedContinuation<Void, Never>] = []

    init(base: SwiftDataHistory) {
        self.base = base
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        guard case .capture = action else {
            return try await base.perform(action)
        }

        captureCount += 1
        guard captureCount == 1 else {
            return try await base.perform(action)
        }

        let waiters = firstCaptureWaiters
        firstCaptureWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            firstCaptureContinuation = continuation
        }

        let base = self.base
        return try await Task.detached {
            try await base.perform(action)
        }.value
    }

    func waitUntilFirstCaptureIsSuspended() async {
        guard captureCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstCaptureWaiters.append(continuation)
        }
    }

    func resumeFirstCapture() {
        let continuation = firstCaptureContinuation
        firstCaptureContinuation = nil
        continuation?.resume()
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        try await base.browse(request)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        await base.observe(request)
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        try await base.details(for: id)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        try await base.pastePayload(for: id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        try await base.thumbnail(for: item, pixels: pixels)
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        try await base.retentionConfiguration()
    }
}

/// Forwards every write and read to one real History authority, delaying only
/// observation pages after the initial snapshot. This exposes the real
/// commit-receipt/observation ordering gap without substituting storage.
private actor PostInitialObservationSuspendingHistory: ClipboardHistory {
    private let base: SwiftDataHistory
    private var heldObservationContinuation: CheckedContinuation<Void, Never>?
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []
    private var isHoldingPostInitialObservation = false

    init(base: SwiftDataHistory) {
        self.base = base
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        try await base.perform(action)
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        try await base.browse(request)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        let upstream = await base.observe(request)
        return AsyncThrowingStream { continuation in
            let producer = Task {
                var emittedInitialPage = false
                do {
                    for try await page in upstream {
                        if emittedInitialPage {
                            await self.holdPostInitialObservation()
                        }
                        guard !Task.isCancelled else { return }
                        continuation.yield(page)
                        emittedInitialPage = true
                    }
                    continuation.finish()
                } catch {
                    guard !Task.isCancelled else { return }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private func holdPostInitialObservation() async {
        isHoldingPostInitialObservation = true
        let waiters = holdWaiters
        holdWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            heldObservationContinuation = continuation
        }
        isHoldingPostInitialObservation = false
    }

    func waitUntilPostInitialObservationIsHeld() async {
        guard !isHoldingPostInitialObservation else { return }
        await withCheckedContinuation { continuation in
            holdWaiters.append(continuation)
        }
    }

    func releasePostInitialObservation() {
        let continuation = heldObservationContinuation
        heldObservationContinuation = nil
        continuation?.resume()
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        try await base.details(for: id)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        try await base.pastePayload(for: id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        try await base.thumbnail(for: item, pixels: pixels)
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        try await base.retentionConfiguration()
    }
}
