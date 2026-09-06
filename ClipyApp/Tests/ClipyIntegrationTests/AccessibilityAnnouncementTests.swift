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
    @Test("replacement warning exposes the cumulative content-free count")
    func replacementWarningShowsCumulativeCount() {
        #expect(
            CaptureNoticePresentation.message(
                for: .replacedCapture(totalReplaced: 1)
            )
                == "Clipy replaced 1 pending clipboard change with a newer "
                    + "one, so it wasn't saved. To try again, copy the older "
                    + "content again."
        )
        #expect(
            CaptureNoticePresentation.message(
                for: .replacedCapture(totalReplaced: 27)
            )
                == "Clipy replaced 27 pending clipboard changes with newer "
                    + "ones, so they weren't saved. To try again, copy the "
                    + "older content again."
        )
    }

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

        composition.viewState.remove(inserted.id)
        try #require(await ComposedSupport.waitFor {
            recorder.records.count == 1
        })

        #expect(recorder.records.count == 1)
        #expect(recorder.records[0].targetsApplication)
        #expect(recorder.records[0].notification == .announcementRequested)
        #expect(recorder.records[0].message == AppHistoryAnnouncementsCopy.text(
            "Item removed from history."
        ))
        #expect(!(recorder.records[0].message?.contains(inserted.id.description) ?? true))
        #expect(surfaceWasAppliedBeforeAnnouncement)
        #expect(
            appDelegate.panelSurfaceState?.appliedPurgeGeneration == 1
        )
        #expect(
            recorder.records[0].priority
                == NSAccessibilityPriorityLevel.medium.rawValue
        )

        composition.viewState.remove(inserted.id)
        try #require(await ComposedSupport.waitFor {
            composition.viewState.failure != nil
        })
        #expect(recorder.records.count == 1)
    }

    @Test("installed settled-search callback announces the bounded count")
    @MainActor
    func settledSearchCountUsesTheAppOwnedAnnouncementBoundary() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let composition = AppComposition.makeForTesting(
            history: history,
            adapter: PasteboardAdapter(
                pasteboard: ComposedSupport.makePasteboard()
            )
        )
        defer { composition.stop() }
        let recorder = AccessibilityAnnouncementRecorder()
        let appDelegate = AppDelegate(
            accessibilityAnnouncementOperations: recorder.operations
        )
        appDelegate.installCompositionForTesting(composition)

        composition.viewState.onSettledSearchResultCount(50, true)

        #expect(recorder.records.count == 1)
        #expect(recorder.records[0].targetsApplication)
        #expect(recorder.records[0].notification == .announcementRequested)
        #expect(recorder.records[0].message == SearchResultCountAnnouncementPresentation.message(
            count: 50, hasNextPage: true
        ))
        #expect(
            recorder.records[0].priority
                == NSAccessibilityPriorityLevel.medium.rawValue
        )
    }

    @Test("history announcements use real app resources and native plural rules",
          arguments: ["en", "zh-Hans"])
    @MainActor
    func localizedHistoryAnnouncements(_ language: String) throws {
        let bundle = try appBundle(language)
        let locale = Locale(identifier: language == "en" ? "en_US" : "zh_Hans_CN")
        let recorder = AccessibilityAnnouncementRecorder()
        let announcement = AccessibilityAnnouncement(operations: recorder.operations)

        announcement.announceHistoryItemRemoved(bundle: bundle)
        for count in [0, 1, 27, 5_000] {
            announcement.announceSettledSearchResultCount(
                count, hasNextPage: false, bundle: bundle, locale: locale
            )
        }
        for count in [0, 1, 5_000] {
            announcement.announceSettledSearchResultCount(
                count, hasNextPage: true, bundle: bundle, locale: locale
            )
        }

        let expected = language == "en"
            ? ["Item removed from history.", "0 results", "1 result", "27 results",
               "5,000 results", "0+ results", "1+ results", "5,000+ results"]
            : ["已从历史记录移除项目。", "0 个结果", "1 个结果", "27 个结果",
               "5,000 个结果", "0+ 个结果", "1+ 个结果", "5,000+ 个结果"]
        #expect(recorder.records.compactMap(\.message) == expected)
        #expect(recorder.records.allSatisfy {
            $0.targetsApplication && $0.notification == .announcementRequested
                && $0.priority == NSAccessibilityPriorityLevel.medium.rawValue
        })
    }

    @Test("announcement language and numeric region are independent")
    func announcementNumericRegion() throws {
        let german = Locale(identifier: "de_DE")
        #expect(SearchResultCountAnnouncementPresentation.message(
            count: 5_000, hasNextPage: false,
            bundle: try appBundle("en"), locale: german
        ) == "5.000 results")
        #expect(SearchResultCountAnnouncementPresentation.message(
            count: 5_000, hasNextPage: true,
            bundle: try appBundle("zh-Hans"), locale: german
        ) == "5.000+ 个结果")
    }

    private func appBundle(_ language: String) throws -> Bundle {
        let localization = try #require(Bundle.main.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(Bundle.main.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent(
            "\(localization).lproj", isDirectory: true
        )))
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
