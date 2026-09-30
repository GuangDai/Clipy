import Foundation
import Testing
@testable import ClipyApp

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

    @Test("search switches the footer to selection and clear hints")
    func shortcutsAndPause() throws {
        let chinese = try bundle("zh-Hans")
        #expect(PanelFooterShortcutHints.text(
            isSearchActive: true, bundle: chinese
        ) == "↑↓ 选择 · Esc 清除")
        #expect(PanelFooterShortcutHints.text(
            isSearchActive: false, bundle: chinese
        ) == "⏎ 粘贴 · Space 快速查看 · ⌘I 详情")
    }
}
