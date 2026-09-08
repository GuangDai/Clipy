import Foundation
import Testing
@testable import ClipyApp

struct DetailsPresentationCopyTests {
    @Test func readableHeadingsKeepDistinctTextEncodings() {
        let english = PanelActionsCopy.bundle(for: Locale(identifier: "en_US"))
        let chinese = PanelActionsCopy.bundle(for: Locale(identifier: "zh_Hans_CN"))
        #expect(DetailsPresentationCopy.formatName("public.utf8-plain-text", bundle: english) == "Text · UTF-8")
        #expect(DetailsPresentationCopy.formatName("public.utf16-plain-text", bundle: english) == "Text · UTF-16")
        #expect(DetailsPresentationCopy.formatName("public.utf16-external-plain-text", bundle: english) == "Text · UTF-16 External")
        #expect(DetailsPresentationCopy.formatName("public.rtf", bundle: chinese) == "富文本")
        #expect(DetailsPresentationCopy.text("Format Details", bundle: chinese) == "格式信息")
    }

    @Test(arguments: ["dyn.example.image", "public.rtf.private", "com.example.e\u{301}.%@"])
    func unknownFormatsRetainTheirExactIdentifier(_ identifier: String) {
        let chinese = PanelActionsCopy.bundle(for: Locale(identifier: "zh_Hans_CN"))
        let name = DetailsPresentationCopy.formatName(identifier, bundle: chinese)
        #expect(name.utf8.elementsEqual(identifier.utf8))
    }
}
