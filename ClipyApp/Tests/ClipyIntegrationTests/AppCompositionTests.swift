/// AppCompositionTests — the composition root's process-side guarantees
/// (docs/roadmap/06-clipyapp.md "Acceptance"; docs/01-architecture.md §8
/// no-second-writer, §5.6 paste orchestration; AppComposition.swift):
///
/// - `AppComposition.open(storeURL:)` rejects a second open over a URL the
///   process already opened with `ClipyCompositionError.storeAlreadyOpen`
///   BEFORE any `ModelContainer` exists (01 §8);
/// - a distinct URL still opens (the guard is per-store, not global);
/// - a FAILED open releases its reservation so a launch-time retry remains
///   possible (AppComposition.open);
/// - the returned composition exposes exactly the assembled surfaces
///   (history/adapter/observer/viewState) wired once at launch.
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

    /// open(storeURL:) (01 §8; roadmap 06): a successful open assembles the
    /// four composed surfaces and wires the paste hand-off; a second open
    /// over the SAME URL throws `ClipyCompositionError.storeAlreadyOpen`
    /// carrying that URL, while a DIFFERENT URL still opens.
    @Test @MainActor
    func secondOpenOverTheSameURLIsRejectedAndDistinctURLsStillOpen() async throws {
        let storeURL = ComposedSupport.tempStoreURL("appcomposition-second-open")
        defer { ComposedSupport.removeStore(storeURL) }

        let composition = try await AppComposition.open(storeURL: storeURL)
        // The assembled surfaces (roadmap 06; 01 §2 composition-root row):
        // the production adapter targets the GENERAL pasteboard and the
        // panel view state rides the same opened history; the paste
        // hand-off's behavior is proven by the orchestration suite below.
        #expect(composition.adapter.pasteboard == .general)
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

        // The reservation was released: clearing the obstacle lets the SAME
        // URL open on the retry (roadmap 06: no poisoned second-open state).
        try FileManager.default.removeItem(at: obstacle)
        _ = try await AppComposition.open(storeURL: blockedURL)
    }
}
