import Testing
import PasteboardAdapter

/// Step-0 scaffold smoke test: asserts the PasteboardAdapter scaffold
/// namespace exists. Real gates land per docs/roadmap README §3.
@Test func scaffoldNamespaceExists() {
    _ = PasteboardAdapterScaffold.self
}
