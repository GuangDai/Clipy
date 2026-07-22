import Testing
import HistoryDomain

/// Step-0 scaffold smoke test: asserts the HistoryDomain scaffold namespace
/// exists. Real walking-skeleton gates land per docs/roadmap README §3
/// (docs/06-cross-cutting.md §8).
@Test func scaffoldNamespaceExists() {
    _ = HistoryDomainScaffold.self
}
