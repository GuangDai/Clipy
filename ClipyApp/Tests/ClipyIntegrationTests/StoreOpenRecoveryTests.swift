/// StoreOpenRecoveryTests — DATA-14's bounded, non-destructive app recovery
/// leaf. The real `AppComposition.open` first fails because a file occupies
/// the requested store directory; after that obstacle is removed, the
/// AppDelegate's explicit Retry opens the same persistent locator. The
/// permission dimension is now pinned here as the SAME flattened failure: a
/// read-only StoreRoot is refused by the app-layer `FileManager` directory
/// creation inside the real open, surfaces the one failure pane, and the
/// visible Retry recovers the exact locator once the permissions return.
/// Reveal is intercepted only at the final Finder boundary so the test
/// account is not disturbed.
///
/// This does not classify SwiftData's underlying corruption/ENOSPC/
/// future-schema errors, quarantine data, or claim a dedicated StoreRoot.
/// The read-only-EXISTING-store-directory shape (directory creation passes,
/// `ModelContainer` construction is refused in the same process) is
/// deliberately NOT composed here: that half is owned by the SPM child
/// characterization, so no CoreData permission diagnostic can reach the
/// hosted log. Those operations remain gated on stable platform evidence
/// and an owning-spec decision (REVIEW DATA-14 / Card 16C).
import Foundation
import HistoryCore
import PresentationUI
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

    @Test("read-only StoreRoot keeps the flat open failure and Retry recovers after chmod")
    func permissionBlockedStoreRootSurfacesOpenFailureAndRetryRecoversAfterPermissionsReturn() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-store-permission-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        // The StoreRoot EXISTS but its owner write bit is removed, so the
        // app-layer `FileManager.createDirectory` inside the real
        // `AppComposition.open` is refused and maps to the same public
        // `.persistence(.openStore)` as the file-occupies fixture above.
        // 0500 keeps read+execute — only writing is refused. Teardown
        // restores write permission BEFORE removing the fixture root, or
        // the cleanup itself is refused and leaves a 0500 directory in TMP.
        let guardedRoot = fixtureRoot.appendingPathComponent(
            "GuardedRoot",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: guardedRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: guardedRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: guardedRoot.path
            )
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        // Fixture self-check: if the runner cannot stage the permission
        // shape, the test would silently prove nothing.
        let stagedPermissions = try FileManager.default.attributesOfItem(
            atPath: guardedRoot.path
        )[.posixPermissions] as? NSNumber
        #expect(stagedPermissions?.int16Value == 0o500)

        let storeDirectory = guardedRoot.appendingPathComponent(
            "HistoryStore",
            isDirectory: true
        )
        let storeURL = storeDirectory.appendingPathComponent("history.store")
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
        // DATA-14: the permission dimension is flattened into the one
        // generic open failure — no permission-specific classifier or
        // wording exists on purpose (macOS 26 offers no usable API).
        #expect(failure == .persistence(.openStore))
        #expect(
            PanelRootView.failureCategory(for: failure)
                == AppRecoveryCopy.text("History Store Open Failed")
        )
        let failureMessage = PanelRootView.failureMessage(for: failure)
        #expect(
            failureMessage
                == FailurePresentation.message(for: .persistence(.openStore))
        )
        #expect(!failureMessage.contains(guardedRoot.path))
        #expect(!failureMessage.contains(storeURL.path))

        // Reveal names the CONFIGURED store directory even though the failed
        // open never created it. Finder is a no-op for a missing directory —
        // a known UX gap recorded, not repaired: pre-creating the directory
        // or repairing permissions from Reveal would break DATA-14's
        // non-destructive boundary.
        appDelegate.revealStoreLocation()
        #expect(revealedDirectories == [storeDirectory])
        #expect(
            !FileManager.default.fileExists(atPath: storeDirectory.path)
        )

        // Recovery changes only the external permissions. The product
        // retries the exact locator; it never chmods, relocates, or falls
        // back to an empty store.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: guardedRoot.path
        )
        let restoredPermissions = try FileManager.default.attributesOfItem(
            atPath: guardedRoot.path
        )[.posixPermissions] as? NSNumber
        #expect(restoredPermissions?.int16Value == 0o700)
        appDelegate.retryCompositionOpen()
        let recovered = await ComposedSupport.waitFor(timeout: 10) {
            appDelegate.composition != nil
        }
        try #require(recovered)
        let composition = try #require(appDelegate.composition)
        #expect(appDelegate.openFailure == nil)
        var isStoreDirectory: ObjCBool = false
        let storeDirectoryExists = FileManager.default.fileExists(
            atPath: storeDirectory.path,
            isDirectory: &isStoreDirectory
        )
        #expect(storeDirectoryExists && isStoreDirectory.boolValue)
        composition.stop()
    }

    @Test("diagnostic categories use only typed content-free failures")
    func diagnosticCategoriesDoNotGuessAnUnderlyingOpenCause() {
        #expect(
            PanelRootView.failureCategory(
                for: HistoryFailure.persistence(.openStore)
            ) == AppRecoveryCopy.text("History Store Open Failed")
        )
        #expect(
            PanelRootView.failureCategory(
                for: HistoryFailure.persistence(.corruptStoredValue)
            ) == AppRecoveryCopy.text("Stored History Unreadable")
        )
        #expect(
            PanelRootView.failureCategory(
                for: HistoryFailure.persistence(.invariantViolation)
            ) == AppRecoveryCopy.text("History Consistency Check Failed")
        )
        #expect(
            PanelRootView.failureCategory(
                for: HistoryFailure.persistence(.transaction)
            ) == AppRecoveryCopy.text("History Startup Transaction Failed")
        )
        #expect(
            PanelRootView.failureCategory(
                for: HistoryFailure.persistence(.storeAlreadyOpen)
            ) == AppRecoveryCopy.text("History Store Already Open")
        )
        // DATA-7a: the cross-process lease denial carries the finding's
        // "in use by another instance" wording, not the generic storage
        // error the flat `.openStore` dimensions share.
        #expect(
            PanelRootView.failureMessage(
                for: HistoryFailure.persistence(.storeAlreadyOpen)
            ) == AppRecoveryCopy.text("Clipy's history store is already open in another instance. Quit that instance and try again.")
        )
        #expect(
            PanelRootView.failureCategory(
                for: ClipyCompositionError.storeAlreadyOpen(
                    URL(fileURLWithPath: "/tmp/clipy-store")
                )
            ) == AppRecoveryCopy.text("History Store Already Open")
        )
    }
}
