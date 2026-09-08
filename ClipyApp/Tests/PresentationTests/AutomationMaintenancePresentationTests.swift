import Foundation
import Testing
@testable import ClipyApp

struct AutomationMaintenancePresentationTests {
    @Test func groupedSettingsLabelsAreAvailableInBothLanguages() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        for (key, translation) in [
            ("Read History", "读取历史"),
            ("Change History", "修改历史"),
            ("Advanced Details", "高级详情"),
            ("Clipboard Content", "剪贴板内容"),
            ("Space on Disk", "磁盘占用"),
            ("Diagnostics", "诊断信息"),
            ("About Content Size", "关于内容用量"),
            ("Copy Path", "复制路径"),
            ("Save a Copy of Your History", "备份剪贴板历史"),
        ] {
            #expect(AutomationMaintenancePresentation.text(key, bundle: english) == key)
            #expect(AutomationMaintenancePresentation.text(key, bundle: chinese) == translation)
        }
        #expect(AutomationMaintenancePresentation.text(
            "Access starts with no permissions. Programs running as your account share the permissions below.",
            bundle: chinese
        ) == "启用后默认不授予任何权限。以你的账户运行的程序共享下方权限。")
        #expect(AutomationMaintenancePresentation.text(
            "Save content changes as new revisions. Earlier content stays retained.", bundle: chinese
        ) == "将内容更改保存为新修订；之前的内容仍会保留。")
    }

    private func bundle(_ language: String) throws -> Bundle {
        let root = try #require(AutomationMaintenancePresentation.bundle.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent("\(language).lproj", isDirectory: true)))
    }
}
