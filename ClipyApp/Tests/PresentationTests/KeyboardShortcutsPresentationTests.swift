import Foundation
@testable import ClipyApp
import Testing

struct KeyboardShortcutsPresentationTests {
    @Test func chineseCopyNamesEveryConfigurableActionAndExplainsConflictRecovery() throws {
        let root = try #require(Bundle.main.resourceURL)
        let bundle = try #require(Bundle(url: root.appendingPathComponent("zh-Hans.lproj", isDirectory: true)))
        #expect(KeyboardShortcutsCopy.text("Keyboard Shortcuts", bundle: bundle) == "快捷键")
        #expect(KeyboardShortcutsCopy.text("Not set", bundle: bundle) == "未设置")
        for action in PanelShortcutAction.allCases {
            #expect(KeyboardShortcutsCopy.text(action.title, bundle: bundle) != action.title)
        }
        let conflict = KeyboardShortcutsCopy.failure(.conflict(.togglePin), bundle: bundle)
        #expect(conflict.contains("置顶或取消置顶选中项目"))
        #expect(conflict.contains("先清空"))
        #expect(!conflict.contains("%@"))
    }

    @Test func englishConflictIdentifiesTheActionWithoutDiscardingRecovery() throws {
        let root = try #require(Bundle.main.resourceURL)
        let bundle = try #require(Bundle(url: root.appendingPathComponent("en.lproj", isDirectory: true)))
        let message = KeyboardShortcutsCopy.failure(.conflict(.focusSearch), bundle: bundle)
        #expect(message.contains("Focus search"))
        #expect(message.contains("clear that action first"))
    }
}
