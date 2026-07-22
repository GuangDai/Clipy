import Testing
@testable import HistoryStorage

/// Step-0 scaffold smoke test: asserts the HistoryStorage scaffold namespace
/// exists. Real walking-skeleton gates land per docs/roadmap README §3
/// (docs/06-cross-cutting.md §8); this target later hosts WS1–WS21 against
/// both persistent temporary stores and in-memory configurations
/// (docs/06-cross-cutting.md §5).
@Test func scaffoldNamespaceExists() {
    _ = HistoryStorageScaffold.self
}
