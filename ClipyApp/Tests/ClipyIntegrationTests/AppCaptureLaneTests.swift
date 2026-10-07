/// AppCaptureLaneTests — REVIEW Card 6's bounded app-owner capture lane.
///
/// The seam is the real `AppComposition` entry plus its content-free health
/// snapshot. Durable assertions always read through a real in-memory
/// `SQLiteHistory`. Test adapters only delay one real boundary operation;
/// every write and read still forwards to that authority.
import AppKit
import Foundation
import HistoryCore
@testable import HistoryStorage
import PasteboardAdapter
import Testing
@testable import ClipyApp

struct AppCaptureLaneTests {

    @Test @MainActor
    func aCaptureSubmittedByTheCompletionHealthCallbackKeepsTheLaneSerialized() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let history = FirstCaptureSuspendingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        defer { pasteboard.releaseGlobally() }
        let composition = AppComposition.makeForTesting(
            history: history, adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        defer { composition.stop() }
        let healthProbe = CaptureHealthProbe()
        var injectOnNextHealth = false
        var injected = false
        composition.onCaptureHealthChanged = { health in
            healthProbe.receive(health)
            guard injectOnNextHealth else { return }
            injectOnNextHealth = false
            injected = true
            composition.submitCaptureForTesting(Self.capture("C", at: 3))
            #expect(composition.captureHealth.activeCommitCount == 1)
            #expect(composition.captureHealth.pendingCaptureCount == 1)
        }

        composition.submitCaptureForTesting(Self.capture("A", at: 1))
        await history.waitUntilFirstCaptureIsSuspended()
        composition.submitCaptureForTesting(Self.capture("B", at: 2))
        injectOnNextHealth = true
        await history.resumeFirstCapture()
        await healthProbe.waitForIdle(failedCaptureCount: 0, lastFailure: nil)

        #expect(injected)
        let page = try await base.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(page.rows.map(\.title) == ["C", "B", "A"])
        #expect(await history.captureAttemptCount == 3)
        #expect(composition.captureHealth.droppedCaptureCount == 0)
    }

    @Test @MainActor
    func stoppingBeforeTheCaptureTaskStartsDoesNotCallHistory() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let history = FirstCaptureSuspendingHistory(base: base, suspendsFirstCapture: false)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        defer { pasteboard.releaseGlobally() }
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )

        composition.submitCaptureForTesting(Self.capture("cancelled before execution", at: 1))
        let task = try #require(composition.activeCaptureForTesting)
        // No suspension between admission and stop: the MainActor task has
        // been allocated, but has not reached the History boundary.
        composition.stop()
        await task.value

        #expect(await history.captureAttemptCount == 0)
        #expect(try await base.browse(HistoryBrowseRequest(kind: .recent, limit: 10)).rows.isEmpty)
        #expect(composition.captureHealth.activeCommitCount == 0)
    }

    /// Every complete observation waits for the preceding commit. The real
    /// receipt order distinguishes FIFO delivery from timestamp-sorted reads.
    @Test @MainActor
    func suspendedCapturePreservesAllPendingValuesInOrder() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let history = FirstCaptureSuspendingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        defer { pasteboard.releaseGlobally() }
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        let healthProbe = CaptureHealthProbe()
        let shellHealthSink = composition.onCaptureHealthChanged
        composition.onCaptureHealthChanged = { health in
            shellHealthSink?(health)
            healthProbe.receive(health)
        }
        defer { composition.stop() }

        composition.submitCaptureForTesting(Self.capture("A", at: 1))
        await history.waitUntilFirstCaptureIsSuspended()
        for (index, text) in ["B", "C", "D"].enumerated() {
            composition.submitCaptureForTesting(
                Self.capture(text, at: TimeInterval(index + 2))
            )
            #expect(composition.captureHealth.activeCommitCount == 1)
            #expect(composition.captureHealth.pendingCaptureCount == index + 1)
            #expect(composition.captureHealth.pendingCaptureBytes == index + 1)
            #expect(composition.captureHealth.droppedCaptureCount == 0)
        }
        #expect(appDelegate.captureHealth.pendingCaptureCount == 3)
        #expect(appDelegate.captureNotice == nil)

        await history.resumeFirstCapture()
        await healthProbe.waitForIdle(failedCaptureCount: 0, lastFailure: nil)
        let page = try await base.browse(.init(kind: .recent, limit: 10))
        #expect(page.rows.map(\.title) == ["D", "C", "B", "A"])
        #expect(await history.committedCaptureIDs == page.rows.reversed().map(\.item.id))
        for row in page.rows {
            let payload = try await base.pastePayload(for: row.item.id)
            #expect(payload.representations.map(\.bytes) == [Data(row.title.utf8)])
        }
        #expect(appDelegate.captureHealth.pendingCaptureBytes == 0)
    }

    /// A thousand observations cannot grow the entry count or replace an
    /// accepted capture. Only the first bounded window becomes History.
    @Test @MainActor
    func thousandCaptureBurstPreservesAcceptedFIFOWithinTheItemBound() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let history = FirstCaptureSuspendingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        defer { pasteboard.releaseGlobally() }
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            captureByteLimit: 1_024
        )
        let appDelegate = AppDelegate()
        appDelegate.installCompositionForTesting(composition)
        let healthProbe = CaptureHealthProbe()
        let shellHealthSink = composition.onCaptureHealthChanged
        var mayRefillDequeuedSlot = false
        var refilledDequeuedSlot = false
        composition.onCaptureHealthChanged = { health in
            shellHealthSink?(health)
            healthProbe.receive(health)
            guard mayRefillDequeuedSlot,
                  health.activeCommitCount == 1,
                  health.pendingCaptureCount == AppComposition.maximumPendingCaptures - 1
            else { return }
            mayRefillDequeuedSlot = false
            refilledDequeuedSlot = true
            composition.submitCaptureForTesting(Self.capture("wrap", at: 1_002))
        }
        defer { composition.stop() }

        composition.submitCaptureForTesting(Self.capture("A000", at: 1))
        await history.waitUntilFirstCaptureIsSuspended()
        let limit = AppComposition.maximumPendingCaptures
        for index in 0..<1_000 {
            composition.submitCaptureForTesting(Self.capture(
                String(format: "%04d", index), at: TimeInterval(index + 2)
            ))
            let retained = min(index + 1, limit)
            let health = composition.captureHealth
            #expect(health.activeCommitCount == 1)
            #expect(health.pendingCaptureCount == retained)
            #expect(health.activeCaptureBytes == 4)
            #expect(health.pendingCaptureBytes == retained * 4)
            #expect(health.droppedCaptureCount == max(0, index + 1 - limit))
            if index == limit {
                #expect(appDelegate.captureNotice == .droppedCapture(totalDropped: 1))
                appDelegate.dismissCaptureNotice()
            } else if index == limit + 1 {
                #expect(appDelegate.captureNotice == .droppedCapture(totalDropped: 2))
            }
        }

        mayRefillDequeuedSlot = true
        await history.resumeFirstCapture()
        await healthProbe.waitForIdle(failedCaptureCount: 0, lastFailure: nil)
        let page = try await base.browse(.init(kind: .recent, limit: 100))
        #expect(refilledDequeuedSlot)
        let acceptedTitles = ["A000"] + (0..<limit).map { String(format: "%04d", $0) } + ["wrap"]
        #expect(page.rows.map(\.title) == Array(acceptedTitles.reversed()))
        #expect(await history.committedCaptureIDs == page.rows.reversed().map(\.item.id))
        #expect(composition.captureHealth.droppedCaptureCount == 1_000 - limit)
        #expect(composition.captureHealth.pendingCaptureBytes == 0)
    }

    /// The byte budget can be reached before the entry count. An oversized
    /// new entry is refused; a later smaller entry may still use free space.
    @Test @MainActor
    func pendingByteBudgetPreservesEarlierCapturesAndAcceptsASmallerLaterCopy() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let history = FirstCaptureSuspendingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        defer { pasteboard.releaseGlobally() }
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard),
            captureByteLimit: 4
        )
        let healthProbe = CaptureHealthProbe()
        composition.onCaptureHealthChanged = { healthProbe.receive($0) }
        defer { composition.stop() }

        composition.submitCaptureForTesting(Self.capture("A", at: 1))
        await history.waitUntilFirstCaptureIsSuspended()
        composition.submitCaptureForTesting(Self.capture("B", at: 2))
        composition.submitCaptureForTesting(Self.capture("CC", at: 3))
        composition.submitCaptureForTesting(Self.capture("DD", at: 4))
        #expect(composition.captureHealth.pendingCaptureCount == 2)
        #expect(composition.captureHealth.pendingCaptureBytes == 3)
        #expect(composition.captureHealth.droppedCaptureCount == 1)
        composition.submitCaptureForTesting(Self.capture("E", at: 5))
        #expect(composition.captureHealth.pendingCaptureCount == 3)
        #expect(composition.captureHealth.pendingCaptureBytes == 4)
        #expect(composition.captureHealth.activeCaptureBytes + composition.captureHealth.pendingCaptureBytes <= 8)

        await history.resumeFirstCapture()
        await healthProbe.waitForIdle(failedCaptureCount: 0, lastFailure: nil)
        let page = try await base.browse(.init(kind: .recent, limit: 10))
        #expect(page.rows.map(\.title) == ["E", "CC", "B", "A"])
        #expect(await history.committedCaptureIDs == page.rows.reversed().map(\.item.id))
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
        composition.submitCaptureForTesting(Self.capture("C", at: 12))
        #expect(composition.captureHealth.pendingCaptureCount == 2)

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

    @Test @MainActor
    func pauseReleasesTheWholePendingQueueWhileAnAdmittedCommitFinishes() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let history = FirstCaptureSuspendingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        defer { pasteboard.releaseGlobally() }
        let composition = AppComposition.makeForTesting(
            history: history, adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        let healthProbe = CaptureHealthProbe()
        composition.onCaptureHealthChanged = { healthProbe.receive($0) }
        defer { composition.stop() }

        composition.submitCaptureForTesting(Self.capture("A", at: 1))
        await history.waitUntilFirstCaptureIsSuspended()
        composition.submitCaptureForTesting(Self.capture("B", at: 2))
        composition.submitCaptureForTesting(Self.capture("C", at: 3))
        composition.pauseCapture()
        #expect(composition.captureAccessState == .userPaused)
        #expect(composition.captureHealth.pendingCaptureCount == 0)
        #expect(composition.captureHealth.pendingCaptureBytes == 0)

        await history.resumeFirstCapture()
        await healthProbe.waitForIdle(failedCaptureCount: 0, lastFailure: nil)
        let page = try await base.browse(.init(kind: .recent, limit: 10))
        #expect(page.rows.map(\.title) == ["A"])
        #expect(await history.captureAttemptCount == 1)
    }

    @Test @MainActor
    func restartingFromFailureHealthDoesNotLetTheOldCompletionClearTheNewTask() async throws {
        let base = try await ComposedSupport.openMemoryHistory()
        let history = FirstCaptureLowDiskFailingHistory(base: base)
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        defer { pasteboard.releaseGlobally() }
        let composition = AppComposition.makeForTesting(
            history: history, adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        let healthProbe = CaptureHealthProbe()
        var restarted = false
        composition.onCaptureHealthChanged = { health in
            healthProbe.receive(health)
            guard !restarted, health.failedCaptureCount == 1 else { return }
            restarted = true
            composition.stop()
            composition.start()
            composition.submitCaptureForTesting(Self.capture("after restart", at: 2))
        }
        defer { composition.stop() }

        composition.submitCaptureForTesting(Self.capture("fails before restart", at: 1))
        await history.waitUntilFirstCaptureIsSuspended()
        let oldTask = try #require(composition.activeCaptureForTesting)
        await history.failFirstCaptureWithLowDisk()
        await oldTask.value
        await healthProbe.waitForIdle(failedCaptureCount: 1, lastFailure: nil)

        #expect(restarted)
        let page = try await base.browse(.init(kind: .recent, limit: 10))
        #expect(page.rows.map(\.title) == ["after restart"])
        #expect(await history.captureAttemptCount == 2)
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
        composition.submitCaptureForTesting(Self.capture("discarded second pending", at: 21.5))
        #expect(composition.captureHealth.pendingCaptureCount == 2)

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

    /// One system copy gesture enters the capture lane as one ordered value.
    @Test @MainActor
    func multiItemClipboardCapturesBothItemsThroughTheAppLane() async throws {
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

        let settled = await ComposedSupport.waitFor {
            composition.captureHealth.activeCommitCount == 0
                && composition.captureHealth.pendingCaptureCount == 0
        }
        #expect(settled)
        #expect(appDelegate.captureNotice == nil)
        let page = try await history.browse(.init(kind: .recent, limit: 10))
        #expect(page.rows.count == 1)
        let item = try #require(page.rows.first?.item)
        let payload = try await history.pastePayload(for: item.id)
        #expect(payload.representations.map(\.pasteboardItemIndex) == [0, 1])
        #expect(payload.representations.map(\.bytes) == [Data("first".utf8), Data("second".utf8)])
        let destination = ComposedSupport.makePasteboard()
        try PasteboardAdapter(pasteboard: destination).write(payload)
        let pasted = try #require(destination.pasteboardItems)
        #expect(pasted.count == 2)
        #expect(pasted[0].data(forType: .string) == Data("first".utf8))
        #expect(pasted[1].data(forType: .string) == Data("second".utf8))
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
        in history: SQLiteHistory
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
    func backup(to directory: URL) async throws -> HistoryBackupReceipt {
        try await base.backup(to: directory)
    }

    private let base: SQLiteHistory
    private var captureAttempts = 0
    private var firstCaptureContinuation: CheckedContinuation<Void, Never>?
    private var firstCaptureWaiters: [CheckedContinuation<Void, Never>] = []

    init(base: SQLiteHistory) {
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

    func sourceApplications(_ request: HistorySourceApplicationRequest) async throws -> HistorySourceApplicationPage {
        try await base.sourceApplications(request)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        await base.observe(request)
    }

    func copySources(
        for id: HistoryItemID, expectedCopyCount: UInt64, offset: Int
    ) async throws -> HistoryCopySourcePage {
        try await base.copySources(for: id, expectedCopyCount: expectedCopyCount, offset: offset)
    }

    func representationMetadata(
        for item: HistoryItemReference
    ) async throws -> [HistoryRepresentationMetadata] {
        try await base.representationMetadata(for: item)
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        try await base.details(for: id)
    }

    func representation(_ request: HistoryRepresentationRequest) async throws -> HistoryRepresentation {
        try await base.representation(request)
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

    func usage() async throws -> HistoryUsage {
        try await base.usage()
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

/// Shared hosted capture-lifecycle adapter: pause capture 1 at the process
/// boundary, then forward every operation/read to the same real store. Its
/// detached forward makes capture 1 intentionally non-cooperative with the
/// caller's cancellation so the stop fence is observable deterministically.
actor FirstCaptureSuspendingHistory: ClipboardHistory {
    func backup(to directory: URL) async throws -> HistoryBackupReceipt {
        try await base.backup(to: directory)
    }

    private let base: SQLiteHistory
    private let suspendsFirstCapture: Bool
    private var captureCount = 0
    private(set) var committedCaptureIDs: [HistoryItemID] = []
    private var firstCaptureContinuation: CheckedContinuation<Void, Never>?
    private var firstCaptureWaiters: [CheckedContinuation<Void, Never>] = []

    init(base: SQLiteHistory, suspendsFirstCapture: Bool = true) {
        self.base = base
        self.suspendsFirstCapture = suspendsFirstCapture
    }

    var captureAttemptCount: Int { captureCount }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        guard case .capture = action else {
            return try await base.perform(action)
        }

        captureCount += 1
        let captureOrdinal = captureCount
        guard captureOrdinal == 1, suspendsFirstCapture else {
            let receipt = try await base.perform(action)
            recordCommittedCapture(receipt)
            return receipt
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
        let receipt = try await Task.detached {
            try await base.perform(action)
        }.value
        recordCommittedCapture(receipt)
        return receipt
    }

    private func recordCommittedCapture(_ receipt: HistoryReceipt) {
        guard case .committed(let commit) = receipt else { return }
        switch commit.outcome {
        case .inserted(let item), .coalesced(let item):
            committedCaptureIDs.append(item.id)
        default:
            break
        }
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

    func sourceApplications(_ request: HistorySourceApplicationRequest) async throws -> HistorySourceApplicationPage {
        try await base.sourceApplications(request)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        await base.observe(request)
    }

    func copySources(
        for id: HistoryItemID, expectedCopyCount: UInt64, offset: Int
    ) async throws -> HistoryCopySourcePage {
        try await base.copySources(for: id, expectedCopyCount: expectedCopyCount, offset: offset)
    }

    func representationMetadata(
        for item: HistoryItemReference
    ) async throws -> [HistoryRepresentationMetadata] {
        try await base.representationMetadata(for: item)
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        try await base.details(for: id)
    }

    func representation(_ request: HistoryRepresentationRequest) async throws -> HistoryRepresentation {
        try await base.representation(request)
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

    func usage() async throws -> HistoryUsage {
        try await base.usage()
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        try await base.retentionConfiguration()
    }
}
