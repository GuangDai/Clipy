/// Compile/catalog evidence for the six-type X.7 surface. System discovery is
/// intentionally outside this unsigned hosted-test claim.
import AppIntents
import Testing
@testable import ClipyApp

@Suite("App Intents catalog (X.7)")
struct AppIntentCatalogTests {
    @Test("provider publishes exactly the six approved shortcuts")
    func sixApprovedShortcuts() {
        #expect(ClipboardShortcuts.appShortcuts.count == 6)
    }

    @Test("all six concrete types satisfy AppIntent")
    func sixConcreteIntentTypesCompile() {
        requireAppIntent(SearchHistoryIntent.self)
        requireAppIntent(GetItemDetailsIntent.self)
        requireAppIntent(PasteItemIntent.self)
        requireAppIntent(PinItemIntent.self)
        requireAppIntent(UnpinItemIntent.self)
        requireAppIntent(RemoveItemIntent.self)
    }

    private func requireAppIntent<T: AppIntent>(_ type: T.Type) {}
}
