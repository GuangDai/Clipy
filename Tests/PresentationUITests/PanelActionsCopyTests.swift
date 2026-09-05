import Foundation
import Testing
@testable import PresentationUI

@Suite("Panel action and revision safety localization")
struct PanelActionsCopyTests {
    private func bundle(_ language: String) throws -> Bundle {
        let localization = try #require(PanelActionsCopy.bundle.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(PanelActionsCopy.bundle.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent(
            "\(localization).lproj", isDirectory: true
        )))
    }

    @Test("both languages disclose immutable revisions and retained originals")
    func revisionSafetyDisclosure() throws {
        #expect(PanelActionsCopy.revisionDisclosure(bundle: try bundle("en")) ==
            "Save appends an immutable revision. Previous and original content "
                + "may remain in this item's revision history.")
        let chinese = try bundle("zh-Hans")
        #expect(PanelActionsCopy.revisionDisclosure(bundle: chinese) ==
            "保存会追加一个不可变的修订版本。先前内容和原始内容可能仍保留在此项目的修订历史中。")
        #expect(PanelActionsCopy.text(
            "Your unsaved changes will be lost.", bundle: chinese
        ) == "未保存的更改将会丢失。")
        #expect(PanelActionsCopy.text(
            "Remove this item from your clipboard history?", bundle: chinese
        ) == "从剪贴板历史记录中移除此项目？")
    }

    @Test("translated accessibility actions preserve literal user titles and format identifiers")
    func literalActionArguments() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        let title = "Budget 100% %@ — 预算"
        #expect(PanelActionsCopy.format("Revert to %@", title, bundle: english) ==
            "Revert to Budget 100% %@ — 预算")
        #expect(PanelActionsCopy.format("Revert to %@", title, bundle: chinese) ==
            "还原为 Budget 100% %@ — 预算")
        #expect(PanelActionsCopy.format(
            "Editing decision for %@", "public.utf8-plain-text", bundle: chinese
        ) == "public.utf8-plain-text 的编辑决定")
    }

    @Test("pin position uses localized words independently of numeric region")
    func pinnedPosition() throws {
        let chinese = try bundle("zh-Hans")
        let locale = Locale(identifier: "de_DE")
        #expect(PanelActionsCopy.pinnedPosition(
            1_234, bundle: chinese, locale: locale
        ) == "置顶位置：1.234")
        #expect(PanelActionsCopy.pinnedPosition(
            1_234, compact: true, bundle: chinese, locale: locale
        ) == "置顶第 1.234 项")
    }
}
