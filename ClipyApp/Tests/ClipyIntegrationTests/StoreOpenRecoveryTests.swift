/// StoreOpenRecoveryTests — DATA-14's bounded, non-destructive app recovery
/// leaf. The real `AppComposition.open` first fails because a file occupies
/// the requested store directory; after that obstacle is removed, the
/// AppDelegate's explicit Retry opens the same persistent locator. Reveal is
/// intercepted only at the final Finder boundary so the test account is not
/// disturbed.
///
/// This does not classify SwiftData's underlying permission/corruption/
/// ENOSPC/future-schema errors, quarantine data, or claim a dedicated
/// StoreRoot. Those operations remain gated on stable platform evidence and
/// an owning-spec decision (REVIEW DATA-14 / Card 16C).
import Foundation
import HistoryCore
import Testing
@testable import ClipyApp

@Suite("Store-open recovery", .serialized)
@MainActor
struct StoreOpenRecoveryTests {

    @Test("running-app Reveal marker requires the exact StoreRoot sibling")
    func runningAppRevealMarkerIsNarrowAndContentFree() throws {
        let configuration = try #require(
            RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH":
                    "/tmp/clipy-store-recovery/unused/../HistoryStore/history.store",
                "CLIPY_UI_TEST_STORE_REVEAL_MARKER_PATH":
                    "/tmp/clipy-store-recovery/clipy-store-reveal.marker",
            ])
        )
        #expect(
            configuration.storeURL
                == URL(
                    fileURLWithPath:
                        "/tmp/clipy-store-recovery/HistoryStore/history.store"
                )
        )
        #expect(
            configuration.storeRevealMarkerURL
                == URL(
                    fileURLWithPath:
                        "/tmp/clipy-store-recovery/clipy-store-reveal.marker"
                )
        )

        let rejectedMarkers = [
            "relative.marker",
            "/tmp/clipy-store-recovery/wrong-name.marker",
            "/tmp/wrong-location/clipy-store-reveal.marker",
            "/tmp/clipy-store-recovery/other/../clipy-store-reveal.marker",
        ]
        for marker in rejectedMarkers {
            #expect(RunningUITestConfiguration.current(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_STORE_PATH":
                    "/tmp/clipy-store-recovery/HistoryStore/history.store",
                "CLIPY_UI_TEST_STORE_REVEAL_MARKER_PATH": marker,
            ]) == nil)
        }
    }

    @Test("failed open supports Reveal and explicit same-locator Retry")
    func failedOpenCanRevealAndRetryTheSamePersistentLocator() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-store-open-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        // A regular file occupies the directory AppComposition must create.
        // This is the same direct failure fixture as AppCompositionTests and
        // maps to the public `.persistence(.openStore)` category.
        let blockedDirectory = fixtureRoot.appendingPathComponent(
            "HistoryStore",
            isDirectory: true
        )
        try Data("not a directory".utf8).write(to: blockedDirectory)
        let storeURL = blockedDirectory.appendingPathComponent("history.store")
        var revealedDirectories: [URL] = []
        let appDelegate = AppDelegate(
            accessibilityAnnouncementOperations: .live,
            storeURL: storeURL,
            revealStoreLocationOperation: { directory in
                revealedDirectories.append(directory)
            }
        )

        appDelegate.openCompositionIfNeeded()
        let failed = await ComposedSupport.waitFor(timeout: 10) {
            appDelegate.openFailure != nil
        }
        try #require(failed)
        #expect(appDelegate.composition == nil)
        let failure = try #require(
            appDelegate.openFailure as? HistoryFailure
        )
        #expect(failure == .persistence(.openStore))

        appDelegate.revealStoreLocation()
        #expect(revealedDirectories == [blockedDirectory])

        // Recovery changes only the external obstacle. The product retries
        // the exact locator; it does not choose an in-memory or empty store.
        try FileManager.default.removeItem(at: blockedDirectory)
        appDelegate.retryCompositionOpen()
        let recovered = await ComposedSupport.waitFor(timeout: 10) {
            appDelegate.composition != nil
        }
        try #require(recovered)
        let composition = try #require(appDelegate.composition)
        #expect(appDelegate.openFailure == nil)
        composition.stop()
    }

    @Test("diagnostic categories use only typed content-free failures")
    func diagnosticCategoriesDoNotGuessAnUnderlyingOpenCause() {
        #expect(
            PanelRootView.failureCategory(
                for: HistoryFailure.persistence(.openStore)
            ) == "History Store Open Failed"
        )
        #expect(
            PanelRootView.failureCategory(
                for: HistoryFailure.persistence(.corruptStoredValue)
            ) == "Stored History Unreadable"
        )
        #expect(
            PanelRootView.failureCategory(
                for: HistoryFailure.persistence(.invariantViolation)
            ) == "History Consistency Check Failed"
        )
        #expect(
            PanelRootView.failureCategory(
                for: HistoryFailure.persistence(.transaction)
            ) == "History Startup Transaction Failed"
        )
        #expect(
            PanelRootView.failureCategory(
                for: ClipyCompositionError.storeAlreadyOpen(
                    URL(fileURLWithPath: "/tmp/clipy-store")
                )
            ) == "History Store Already Open"
        )
    }
}
