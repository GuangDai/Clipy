import Foundation
import Testing
@testable import ClipyApp

struct MaintenanceSettingsCopyTests {
    @Test("backup outcome selects its count or recovery message")
    func backupStatus() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        #expect(MaintenanceSettingsCopy.backupStatus(.completed(itemCount: 3), bundle: english)
            == "Backup complete. Retained items: 3.")
        #expect(MaintenanceSettingsCopy.backupStatus(.completed(itemCount: 3), bundle: chinese)
            == "备份完成，已保留 3 条记录。")
        #expect(MaintenanceSettingsCopy.backupStatus(.cancelled, bundle: chinese) == "备份已取消。")
        #expect(MaintenanceSettingsCopy.backupStatus(.failed(.destinationAlreadyExists), bundle: chinese)
            == "请选择新的备份文件夹。不能替换已有文件或文件夹。")
        #expect(MaintenanceSettingsCopy.backupStatus(.failed(.writeFailed), bundle: chinese)
            == "无法保存备份。请检查可用磁盘空间和文件夹权限后重试。")
    }

    private func bundle(_ language: String) throws -> Bundle {
        let resources = MaintenanceSettingsCopy.bundle
        let localization = try #require(resources.localizations.first {
            $0.caseInsensitiveCompare(language) == .orderedSame
        })
        let root = try #require(resources.resourceURL)
        return try #require(Bundle(url: root.appendingPathComponent("\(localization).lproj")))
    }
}
