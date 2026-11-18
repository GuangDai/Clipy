/// Card 5A's platform-value translation. AppKit's access behavior is read at
/// the adapter boundary; callers receive only Clipy's neutral immutable value.
import AppKit
import Foundation
import Testing
@testable import PasteboardAdapter

@Suite("Pasteboard access behavior")
struct PasteboardAccessTests {
    @Test("a named private pasteboard exposes the neutral allowed value")
    @MainActor
    func privatePasteboardUsesPublicNeutralProjection() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "com.clipy.pasteboardaccesstests." + UUID().uuidString
            )
        )
        defer { pasteboard.releaseGlobally() }
        let adapter = PasteboardAdapter(pasteboard: pasteboard)

        #expect(adapter.captureAccessBehavior == .allowed)
    }
}
