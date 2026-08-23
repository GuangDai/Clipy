/// Card 5A's platform-value translation. AppKit's access behavior is read at
/// the adapter boundary; callers receive only Clipy's neutral immutable value.
import AppKit
import Foundation
import Testing
@testable import PasteboardAdapter

@Suite("Pasteboard access behavior")
struct PasteboardAccessTests {
    @Test("every documented AppKit behavior maps to one neutral value")
    func documentedBehaviorsMapWithoutLeakingAppKit() {
        #expect(PasteboardAccessBehavior(systemValue: .default) == .systemDefault)
        #expect(PasteboardAccessBehavior(systemValue: .ask) == .ask)
        #expect(PasteboardAccessBehavior(systemValue: .alwaysAllow) == .allowed)
        #expect(PasteboardAccessBehavior(systemValue: .alwaysDeny) == .denied)
    }

    @Test("a named private pasteboard exposes the neutral allowed value")
    @MainActor
    func privatePasteboardUsesPublicNeutralProjection() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "com.clipy.pasteboardaccesstests." + UUID().uuidString
            )
        )
        let adapter = PasteboardAdapter(pasteboard: pasteboard)

        #expect(adapter.captureAccessBehavior == .allowed)
    }
}
