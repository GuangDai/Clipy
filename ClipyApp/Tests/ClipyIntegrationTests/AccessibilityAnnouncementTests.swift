/// Card 15D tests the app-owned announcement boundary at the same
/// capture-health callback consumed by the panel. The substituted operation
/// records only content-free announcement text; no AX tree or assistive
/// technology is required by this hosted seam.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import Testing
@testable import ClipyApp

@MainActor
private final class AccessibilityAnnouncementRecorder {
    struct Record {
        let targetsApplication: Bool
        let notification: NSAccessibility.Notification
        let message: String?
        let priority: Int?
    }

    private(set) var records: [Record] = []
    var onRecord: (() -> Void)?

    var operations: AccessibilityAnnouncementOperations {
        AccessibilityAnnouncementOperations {
            [weak self] element,
            notification,
            userInfo in
            self?.onRecord?()
            self?.records.append(Record(
                targetsApplication: (element as AnyObject) === NSApp,
                notification: notification,
                message: userInfo?[.announcement] as? String,
                priority: userInfo?[.priority] as? Int
            ))
        }
    }
}

@Suite("Capture accessibility announcements (Card 15D)")
struct AccessibilityAnnouncementTests {
    @Test("one authoritative capture failure episode announces once")
    @MainActor
    func newFailureEpisodeAnnouncesOnce() {
        let recorder = AccessibilityAnnouncementRecorder()
        let appDelegate = AppDelegate(
            accessibilityAnnouncementOperations: recorder.operations
        )
        let failed = Self.health(
            failedCaptureCount: 1,
            lastFailure: .invalidInput
        )

        appDelegate.receiveCaptureHealthForTesting(failed)
        appDelegate.receiveCaptureHealthForTesting(failed)

        #expect(recorder.records.count == 1)
        #expect(recorder.records[0].targetsApplication)
        #expect(recorder.records[0].notification == .announcementRequested)
        #expect(
            recorder.records[0].priority
                == NSAccessibilityPriorityLevel.high.rawValue
        )
        #expect(
            recorder.records[0].message
                == "A clipboard change wasn't saved. Clipy can't retry it "
                    + "automatically; copy the content again to make a new attempt."
        )
    }

    @Test("dismiss is silent and the same failure in a new episode reannounces")
    @MainActor
    func repeatedFailureValueUsesEpisodeIdentity() {
        let recorder = AccessibilityAnnouncementRecorder()
        let appDelegate = AppDelegate(
            accessibilityAnnouncementOperations: recorder.operations
        )

        appDelegate.receiveCaptureHealthForTesting(Self.health(
            failedCaptureCount: 1,
            lastFailure: .invalidInput
        ))
        appDelegate.dismissCaptureNotice()
        #expect(recorder.records.count == 1)

        appDelegate.receiveCaptureHealthForTesting(Self.health(
            failedCaptureCount: 2,
            lastFailure: .invalidInput
        ))

        #expect(recorder.records.count == 2)
        #expect(recorder.records[0].message == recorder.records[1].message)
        #expect(appDelegate.captureNotice == .failed(.invalidInput))
    }

    @Test("a stale success neither clears nor announces over a newer failure")
    @MainActor
    func staleSuccessCannotSupersedeFailureEpisode() {
        let recorder = AccessibilityAnnouncementRecorder()
        let appDelegate = AppDelegate(
            accessibilityAnnouncementOperations: recorder.operations
        )
        appDelegate.receiveCaptureHealthForTesting(Self.health(
            failedCaptureCount: 1,
            lastFailure: .invalidInput
        ))

        appDelegate.receiveCaptureHealthForTesting(Self.health(
            failedCaptureCount: 0,
            lastFailure: nil
        ))

        #expect(recorder.records.count == 1)
        #expect(appDelegate.captureNotice == .failed(.invalidInput))
        #expect(appDelegate.captureHealth.failedCaptureCount == 1)
    }

    @Test("replacement and authoritative recovery do not announce")
    @MainActor
    func nonfailureCaptureHealthIsSilent() {
        let recorder = AccessibilityAnnouncementRecorder()
        let appDelegate = AppDelegate(
            accessibilityAnnouncementOperations: recorder.operations
        )
        appDelegate.receiveCaptureHealthForTesting(Self.health(
            replacedCaptureCount: 1,
            failedCaptureCount: 0,
            lastFailure: nil
        ))
        appDelegate.receiveCaptureHealthForTesting(Self.health(
            replacedCaptureCount: 1,
            failedCaptureCount: 1,
            lastFailure: .invalidInput
        ))
        appDelegate.receiveCaptureHealthForTesting(Self.health(
            replacedCaptureCount: 1,
            failedCaptureCount: 1,
            lastFailure: nil
        ))

        #expect(recorder.records.count == 1)
        #expect(appDelegate.captureNotice == nil)
    }

    @Test("committed panel remove announces once; later not-found is silent")
    @MainActor
    func committedPanelRemovalAnnouncesOnce() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("remove-announcement".utf8)
            )],
            origin: CopyOriginObservation(
                sourceApplication: "ClipyIntegrationTests",
                lineageHint: nil
            ),
            observedAt: Date(timeIntervalSinceReferenceDate: 930_000_100)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let inserted) = commit.outcome
        else {
            Issue.record("expected inserted announcement target")
            return
        }
        let pasteboard = ComposedSupport.makePasteboard()
        pasteboard.clearContents()
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(pasteboard: pasteboard)
        )
        defer { composition.stop() }
        let recorder = AccessibilityAnnouncementRecorder()
        let appDelegate = AppDelegate(
            accessibilityAnnouncementOperations: recorder.operations
        )
        var surfaceWasAppliedBeforeAnnouncement = false
        recorder.onRecord = { [weak appDelegate] in
            surfaceWasAppliedBeforeAnnouncement =
                appDelegate?.panelSurfaceState?.appliedPurgeGeneration == 1
        }
        appDelegate.installCompositionForTesting(composition)

        _ = try await composition.viewState.removeAwaitingReceipt(inserted.id)

        #expect(recorder.records.count == 1)
        #expect(recorder.records[0].targetsApplication)
        #expect(recorder.records[0].notification == .announcementRequested)
        #expect(recorder.records[0].message == "Item removed from history.")
        #expect(surfaceWasAppliedBeforeAnnouncement)
        #expect(
            appDelegate.panelSurfaceState?.appliedPurgeGeneration == 1
        )
        #expect(
            recorder.records[0].priority
                == NSAccessibilityPriorityLevel.medium.rawValue
        )

        await #expect(throws: HistoryFailure.self) {
            _ = try await composition.viewState.removeAwaitingReceipt(
                inserted.id
            )
        }
        #expect(recorder.records.count == 1)
    }

    private static func health(
        replacedCaptureCount: Int = 0,
        failedCaptureCount: Int,
        lastFailure: ClipyCaptureFailure?
    ) -> ClipyCaptureHealth {
        ClipyCaptureHealth(
            activeCommitCount: 0,
            activeCaptureBytes: 0,
            pendingCaptureCount: 0,
            pendingCaptureBytes: 0,
            replacedCaptureCount: replacedCaptureCount,
            failedCaptureCount: failedCaptureCount,
            lastFailure: lastFailure
        )
    }
}
