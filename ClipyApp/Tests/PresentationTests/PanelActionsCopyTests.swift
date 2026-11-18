import Foundation
import Testing
@testable import ClipyApp

@Suite("Panel action and revision safety localization")
struct PanelActionsCopyTests {
    @Test("editor byte labels retain English output and follow the view locale")
    func editorByteLabelsFollowLocale() {
        let english = Locale(identifier: "en_US")
        #expect(EditorFormat.bytes(1, locale: english) == "1 byte")
        #expect(EditorFormat.bytes(70, locale: english) == "70 bytes")
        let chinese = EditorFormat.bytes(70, locale: Locale(identifier: "zh_Hans_CN"))
        #expect(chinese.contains("70") && chinese.contains("字节"))
    }

    @Test(arguments: ["en_US", "zh_Hans_SG"])
    func localizedRevertTitlePreservesItsLiteralBytes(localeIdentifier: String) {
        let bundle = PanelActionsCopy.bundle(for: Locale(identifier: localeIdentifier))
        let title = "Cafe\u{301} 100% %@ — 预算"
        let action = PanelActionsCopy.format("Revert to %@", title, bundle: bundle)
        #expect(action.range(of: title, options: .literal) != nil)
    }

    @Test("pin position uses localized words independently of numeric region")
    func pinnedPosition() {
        let chinese = AppLocalization.bundle(for: AppLanguage.simplifiedChinese)
        let locale = Locale(identifier: "de_DE")
        let full = PanelActionsCopy.pinnedPosition(1_234, bundle: chinese, locale: locale)
        let compact = PanelActionsCopy.pinnedPosition(1_234, compact: true, bundle: chinese, locale: locale)
        #expect(full.contains("置顶") && full.contains("1.234"))
        #expect(compact.contains("置顶") && compact.contains("1.234"))
        #expect(full != compact)
    }
}
