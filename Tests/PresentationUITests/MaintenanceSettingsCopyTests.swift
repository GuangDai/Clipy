import Foundation
import Testing
@testable import PresentationUI

struct MaintenanceSettingsCopyTests {
    @Test("Maintenance labels distinguish content from folder allocation in both languages")
    func translatedFactsAndScope() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        #expect(MaintenanceSettingsCopy.text("Logical Content Size", bundle: english)
            == "Logical Content Size")
        #expect(MaintenanceSettingsCopy.text("Store Folder Size", bundle: chinese)
            == "存储文件夹大小")
        #expect(MaintenanceSettingsCopy.text("Unavailable", bundle: chinese) == "暂不可用")
        #expect(MaintenanceSettingsCopy.logicalDisclosure(bundle: chinese)
            == "原始内容与保留的修订版本，不包括数据库及文件系统开销。")
        #expect(MaintenanceSettingsCopy.folderDisclosure(bundle: english)
            == "Approximate allocated size of all files in this folder, including hidden files "
                + "and any other data stored here. Linked files and folders are excluded. "
                + "Live writes and shared disk blocks can affect this estimate.")
        #expect(MaintenanceSettingsCopy.folderDisclosure(bundle: chinese)
            == "此文件夹内所有文件的近似磁盘分配空间，包括隐藏文件及存放在此处的其他数据，不包括链接的文件和文件夹。实时写入与共享磁盘块可能影响此估算值。")
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
