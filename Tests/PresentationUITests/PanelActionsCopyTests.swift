import Foundation
import Testing
@testable import PresentationUI

@Suite("Panel action and revision safety localization")
struct PanelActionsCopyTests {
    @Test func representationExportCopyHasEnglishAndChineseValues() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        #expect(PanelActionsCopy.text("Save As…", bundle: english) == "Save As…")
        #expect(PanelActionsCopy.text("Save As…", bundle: chinese) == "另存为…")
        #expect(PanelActionsCopy.format("Save %@ As…", "public.png", bundle: chinese) == "将 public.png 另存为…")
        #expect(PanelActionsCopy.text("Clipy couldn't save this file. Choose another location and try again.", bundle: chinese)
            == "Clipy 无法保存此文件。请选择其他位置后重试。")
    }

    @Test("editor byte labels retain English output and follow the view locale")
    func editorByteLabelsFollowLocale() {
        let english = Locale(identifier: "en_US")
        #expect(EditorFormat.bytes(1, locale: english) == "1 byte")
        #expect(EditorFormat.bytes(4, locale: english) == "4 bytes")
        #expect(EditorFormat.bytes(13, locale: english) == "13 bytes")
        #expect(EditorFormat.bytes(70, locale: english) == "70 bytes")
        let chinese = EditorFormat.bytes(70, locale: Locale(identifier: "zh_Hans_CN"))
        #expect(chinese.contains("70") && chinese.contains("字节"))
        #expect(EditorFormat.bytes(70, locale: english) == "70 bytes")
    }

    @Test("view locale switches existing editor resources without a process-language cache")
    func editorLocaleChanges() {
        let englishDisclosure = "Save appends an immutable revision. Previous and original content "
            + "may remain in this item's revision history."
        for (identifier, button, disclosure) in [
            ("en_US", "Keep Current", englishDisclosure),
            ("zh_Hans_CN", "保留当前", "保存会追加一个不可变的修订版本。先前内容和原始内容可能仍保留在此项目的修订历史中。"),
            ("en_GB", "Keep Current", englishDisclosure),
        ] {
            let selected = PanelActionsCopy.bundle(for: Locale(identifier: identifier))
            #expect(PanelActionsCopy.text("Keep Current", bundle: selected) == button)
            #expect(ReviseEditorPresentation.revisionDisclosure(bundle: selected) == disclosure)
        }
    }

    @Test("unsupported view language falls back to the module development localization")
    func unsupportedLocaleUsesDevelopmentLanguage() throws {
        #expect(PanelActionsCopy.bundle.developmentLocalization == "en")
        let selected = PanelActionsCopy.bundle(for: Locale(identifier: "fr_FR"))
        let english = try bundle("en")
        #expect(selected.bundleURL == english.bundleURL)
        #expect(PanelActionsCopy.text("Reload Latest", bundle: selected) == "Reload Latest")
    }

    @Test("locale-selected resources preserve literal format arguments and typed failure copy")
    func localeSelectedLiteralAndFailureCopy() {
        let chinese = PanelActionsCopy.bundle(for: Locale(identifier: "zh_Hans_SG"))
        let literal = "com.example.format.%@.100% — **原样**"
        #expect(PanelActionsCopy.format(
            "Replacement text for %@", literal, bundle: chinese
        ) == "com.example.format.%@.100% — **原样** 的替换文本")
        #expect(FailurePresentation.message(
            for: .temporarilyUnavailable(.factProof), bundle: chinese
        ) == "历史记录正忙，请稍后重试。")
    }

    @Test("details metadata and recovery copy use native resources")
    func detailsMetadataAndRecovery() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        for (key, translation) in [
            ("Info", "信息"),
            ("First Copied", "首次复制"),
            ("Last Copied", "最近复制"),
            ("Copy Count", "复制次数"),
            ("Source", "来源"),
            ("Unknown", "未知"),
            ("Content Version", "内容版本"),
            ("Clipboard Item", "剪贴板项目"),
            ("This item changed while you were viewing it. Details reloaded.", "查看期间此项目已更改，详情已重新加载。"),
            ("Clipy couldn't load this item.", "Clipy 无法加载此项目。"),
            ("Clipy couldn't update this item.", "Clipy 无法更新此项目。"),
            ("Clipy couldn't remove this item.", "Clipy 无法移除此项目。"),
        ] {
            #expect(PanelActionsCopy.text(key, bundle: english) == key)
            #expect(PanelActionsCopy.text(key, bundle: chinese) == translation)
        }
    }

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
        #expect(PanelActionsCopy.text(
            " Replace edits UTF-8 or UTF-16 plain text while preserving its encoding.",
            bundle: chinese
        ) == "“替换”编辑 UTF-8 或 UTF-16 纯文本，并保留其编码。")
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
            "Editing decision for %@", "public.utf16-external-plain-text", bundle: chinese
        ) == "public.utf16-external-plain-text 的编辑决定")
    }

    @Test("editor explains independent formats and destination-app choice in both languages")
    func formatIndependenceDisclosure() throws {
        #expect(ReviseEditorPresentation.formatIndependenceDisclosure(bundle: try bundle("en")) ==
            "Editing one format leaves other kept formats unchanged. The destination app may use those formats instead.")
        #expect(ReviseEditorPresentation.formatIndependenceDisclosure(bundle: try bundle("zh-Hans")) ==
            "编辑一种格式不会改变其他保留的格式。目标应用可能改用这些格式。")
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
