import Foundation
import Testing
@testable import ClipyApp

struct DetailsPresentationCopyTests {
    @Test(arguments: ["dyn.example.image", "public.rtf.private", "com.example.e\u{301}.%@"])
    func unknownFormatsRetainTheirExactIdentifier(_ identifier: String) {
        let chinese = PanelActionsCopy.bundle(for: Locale(identifier: "zh_Hans_CN"))
        let name = DetailsPresentationCopy.formatName(identifier, bundle: chinese)
        #expect(name.utf8.elementsEqual(identifier.utf8))
    }
}
