/// AppCompositionTests — the composition root's process-side guarantees
/// (docs/roadmap/06-clipyapp.md "Acceptance"; docs/01-architecture.md §8
/// no-second-writer, §5.6 paste orchestration; AppComposition.swift):
///
/// - `AppComposition.open(storeURL:)` rejects a second open over the same
///   canonical StoreRoot, including standardized/`..` and symlink aliases,
///   with `ClipyCompositionError.storeAlreadyOpen` BEFORE any second
///   `ModelContainer` exists (01 §8; REVIEW PLAY-DISK-0A);
/// - a distinct URL still opens (the guard is per-store, not global);
/// - a FAILED open releases its reservation so a launch-time retry remains
///   possible (AppComposition.open);
/// - the returned composition exposes its app-owned History/view state
///   wired once at launch. Adapter behavior is proved through the real
///   copy lane instead of inspecting its raw AppKit dependency.
///
/// `@testable import ClipyApp` reaches the internal `AppComposition` and
/// `ClipyCompositionError` (roadmap 06 acceptance targets them). Every
/// store lives in a temp directory created upfront (repo convention).
/// `NSApp.hide` and the capture `Timer` are main-runloop side effects with
/// no assertable History state and are not driven here.
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter
import PresentationUI
import Testing
@testable import ClipyApp

struct AppCompositionTests {

    /// Card 14C launch ordering: the final MainActor provider is sampled
    /// immediately before `start`, so an app graph opened while its workspace
    /// is inactive never starts pasteboard observation. Applying the active
    /// facts later restarts that same owner; named-pasteboard lifecycle tests
    /// separately prove the baseline/no-import behavior.
    @Test @MainActor
    func inactiveWorkspaceProviderGatesTheInitialObserverStart() async throws {
        let storeURL = ComposedSupport.tempStoreURL(
            "appcomposition-inactive-workspace"
        )
        defer { ComposedSupport.removeStore(storeURL) }
        let inactive = WorkspaceActivityState(
            isSystemAwake: false,
            isLoginSessionActive: true
        )
        let composition = try await AppComposition.openForUITesting(
            storeURL: storeURL,
            initialCaptureAccessBehavior: .allowed,
            currentCaptureAccessBehavior: .allowed,
            workspaceActivityProvider: { inactive }
        )
        defer { composition.stop() }

        #expect(composition.workspaceActivityForTesting == inactive)
        #expect(!composition.isCaptureObservationActiveForTesting)

        composition.updateWorkspaceActivity(.active)
        #expect(composition.workspaceActivityForTesting == .active)
        #expect(composition.isCaptureObservationActiveForTesting)
    }

    /// open(storeURL:) (01 §8; roadmap 06): a successful open assembles the
    /// four composed surfaces and wires the paste hand-off; a second open
    /// over the SAME URL throws `ClipyCompositionError.storeAlreadyOpen`
    /// carrying that URL, while a DIFFERENT URL still opens.
    @Test @MainActor
    func secondOpenOverTheSameURLIsRejectedAndDistinctURLsStillOpen() async throws {
        let storeURL = ComposedSupport.tempStoreURL("appcomposition-second-open")
        defer { ComposedSupport.removeStore(storeURL) }

        let composition = try await AppComposition.open(storeURL: storeURL)
        // The assembled surface (roadmap 06; 01 §2 composition-root row):
        // the panel view state rides the opened History. The real adapter
        // behavior is covered by AppPasteOrchestrationTests' byte/lineage
        // round trip and ClipboardJourneyUITests' production General-board
        // write; this test does not expose or inspect the raw AppKit object.
        #expect(composition.viewState.pageLimit == 50)

        // A DIFFERENT URL still opens — the guard is per-store (01 §8),
        // not a global one-composition limit.
        let secondURL = ComposedSupport.tempStoreURL("appcomposition-distinct")
        defer { ComposedSupport.removeStore(secondURL) }
        let secondComposition = try await AppComposition.open(storeURL: secondURL)
        #expect(secondComposition.viewState.pageLimit == 50)

        do {
            _ = try await AppComposition.open(storeURL: storeURL)
            Issue.record(
                "AppComposition: expected storeAlreadyOpen for the repeated URL"
            )
        } catch let error as ClipyCompositionError {
            #expect(
                error == .storeAlreadyOpen(storeURL),
                "AppComposition (01 §8): the rejection carries the contested URL"
            )
        }
    }

    /// DATA-7a / PLAY-DISK-0A: path spelling is evidence, not writer
    /// identity. A lexical `..` alias and a filesystem symlink alias that
    /// reach the already-open store must both hit the same pre-open
    /// reservation. The error keeps the requested URL so launch diagnostics
    /// describe the caller's contested path.
    @Test @MainActor
    func standardizedAndSymlinkAliasesCannotBypassSecondOpenGuard() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-composed-store-identity-\(UUID().uuidString)",
                isDirectory: true
            )
        let physicalRoot = fixtureRoot.appendingPathComponent(
            "physical",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: physicalRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let storeURL = physicalRoot.appendingPathComponent("history.store")
        _ = try await AppComposition.open(storeURL: storeURL)

        let standardizedAlias = URL(
            fileURLWithPath:
                physicalRoot.path + "/unused/../history.store"
        )
        let symbolicRoot = fixtureRoot.appendingPathComponent(
            "symbolic",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: symbolicRoot,
            withDestinationURL: physicalRoot
        )
        let symlinkAlias = symbolicRoot.appendingPathComponent("history.store")

        for alias in [standardizedAlias, symlinkAlias] {
            do {
                _ = try await AppComposition.open(storeURL: alias)
                Issue.record(
                    "AppComposition: expected canonical storeAlreadyOpen for \(alias.path)"
                )
            } catch let error as ClipyCompositionError {
                #expect(
                    error == .storeAlreadyOpen(alias),
                    "AppComposition: canonical identity rejection carries the requested alias"
                )
            }
        }
    }

    /// open(storeURL:) failure path (AppComposition.open): a store URL whose
    /// parent directory cannot be created (a FILE occupies the path) fails
    /// `.persistence(.openStore)` and RELEASES its reservation — the retry
    /// after clearing the obstacle succeeds (no poisoned URL).
    @Test @MainActor
    func failedOpenReleasesItsReservationSoRetryRemainsPossible() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipy-composed-open-failure-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        // A plain file where the store's parent DIRECTORY must go:
        // createDirectory fails, the open fails .openStore.
        let obstacle = directory.appendingPathComponent("obstacle")
        try Data("not a directory".utf8).write(to: obstacle)
        let blockedURL = obstacle.appendingPathComponent("history.store")

        do {
            _ = try await AppComposition.open(storeURL: blockedURL)
            Issue.record(
                "AppComposition: expected .persistence(.openStore) for the blocked path"
            )
            return
        } catch let failure as HistoryFailure {
            #expect(
                failure == .persistence(.openStore),
                "AppComposition: directory-creation failures surface as .openStore"
            )
        }

        // The canonical reservation was released: clearing the obstacle lets
        // a standardized alias of the SAME URL open on retry (roadmap 06: no
        // poisoned second-open state).
        try FileManager.default.removeItem(at: obstacle)
        let retryAlias = URL(
            fileURLWithPath:
                obstacle.path + "/unused/../history.store"
        )
        _ = try await AppComposition.open(storeURL: retryAlias)
    }
}
