import Foundation
import Testing
@testable import ClipyApp

struct MaintenanceSettingsCopyTests {
    @Test("backup outcome selects its count or recovery message")
    func backupStatus() {
        for language in [AppLanguage.english, .simplifiedChinese] {
            let bundle = AppLocalization.bundle(for: language)
            #expect(MaintenanceSettingsCopy.backupStatus(.completed(itemCount: 431), bundle: bundle).contains("431"))
        }
        let chinese = AppLocalization.bundle(for: AppLanguage.simplifiedChinese)
        #expect(MaintenanceSettingsCopy.backupStatus(.failed(.destinationAlreadyExists), bundle: chinese)
            .contains("新的备份文件夹"))
        #expect(MaintenanceSettingsCopy.backupStatus(.failed(.writeFailed), bundle: chinese)
            .contains("磁盘空间"))
    }
}
