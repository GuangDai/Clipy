import Testing
import HistoryCore

/// Step-0 scaffold smoke test: asserts the HistoryCore scaffold namespace
/// exists. Real walking-skeleton gates land per docs/roadmap README §3
/// (docs/06-cross-cutting.md §8).
@Test func scaffoldNamespaceExists() {
    _ = HistoryCoreScaffold.self
}
