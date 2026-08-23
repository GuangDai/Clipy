/// Card 15D tests the app-owned announcement boundary at the same
/// capture-health callback consumed by the panel. The substituted operation
/// records only content-free announcement text; no AX tree or assistive
/// technology is required by this hosted seam.
import AppKit
import Testing
@testable import ClipyApp

@MainActor
private final class AccessibilityAnnouncementRecorder {
    struct Record {
        let targetsApplication: Bool
        let notification: NSAccessibility.Notification
        let message: String?
    }

    private(set) var records: [Record] = []

    var operations: AccessibilityAnnouncementOperations {
        AccessibilityAnnouncementOperations {
            [weak self] element,
            notification,
            userInfo in
            self?.records.append(Record(
                targetsApplication: (element as AnyObject) === NSApp,
                notification: notification,
                message: userInfo?[.announcement] as? String
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
