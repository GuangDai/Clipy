import Foundation
import Testing
@testable import PresentationUI

@Suite("Panel footer localization")
struct PanelFooterCopyTests {
    private func bundle(_ language: String) throws -> Bundle {
        let localization = try #require(PanelFooterCopy.bundle.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(PanelFooterCopy.bundle.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent(
            "\(localization).lproj", isDirectory: true
        )))
    }

    @Test("clear scopes retain their distinct destructive meaning in both languages")
    func clearScopes() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        #expect(PanelFooterCopy.text(
            "All unpinned items will be removed. Pinned items are kept.", bundle: english
        ) == "All unpinned items will be removed. Pinned items are kept.")
        #expect(PanelFooterCopy.text(
            "All unpinned items will be removed. Pinned items are kept.", bundle: chinese
        ) == "所有未置顶项目都将被移除，置顶项目将被保留。")
        #expect(PanelFooterCopy.text(
            "All clipboard history, including pinned items, will be removed.", bundle: chinese
        ) == "全部剪贴板历史记录（包括置顶项目）都将被移除。")
    }

    @Test("translated footer keeps the actual keyboard chords and timed pause")
    func shortcutsAndPause() throws {
        let chinese = try bundle("zh-Hans")
        #expect(PanelFooterShortcutHints.text(
            isSearchActive: true, bundle: chinese
        ) == "↑↓ 选择 · Esc 清除")
        #expect(PanelFooterShortcutHints.text(
            isSearchActive: false, bundle: chinese
        ) == "⏎ 粘贴 · Space 快速查看 · ⌘I 详情")
        #expect(PanelFooterCopy.text(
            "Pause Clipboard Monitoring for 5 Minutes", bundle: chinese
        ) == "暂停剪贴板监测 5 分钟")
    }
}
