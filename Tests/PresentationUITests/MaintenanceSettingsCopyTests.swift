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

    @Test("cache absence and whole-process memory scope are explicit in both languages")
    func cacheAndMemoryScope() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        #expect(MaintenanceSettingsCopy.text("Derived Disk Cache", bundle: english)
            == "Derived Disk Cache")
        #expect(MaintenanceSettingsCopy.text("Not Used", bundle: chinese) == "未使用")
        #expect(MaintenanceSettingsCopy.text("Resident Memory (RSS)", bundle: chinese)
            == "驻留内存（RSS）")
        #expect(MaintenanceSettingsCopy.text("Peak Resident Memory", bundle: chinese)
            == "驻留内存峰值")
        #expect(MaintenanceSettingsCopy.text("Memory Footprint", bundle: chinese)
            == "进程内存占用")
        #expect(MaintenanceSettingsCopy.cacheDisclosure(bundle: english)
            == "Thumbnail and preview results are retained in memory. This version has no derived disk cache.")
        #expect(MaintenanceSettingsCopy.cacheDisclosure(bundle: chinese)
            == "缩略图和预览结果保留在内存中，此版本不使用磁盘衍生缓存。")
        #expect(MaintenanceSettingsCopy.memoryDisclosure(bundle: english)
            == "Kernel readings for the whole Clipy process. RSS is currently resident memory; "
                + "footprint is memory charged to the process. Peak RSS is since launch. "
                + "These values include app and framework work, not just clipboard content or caches.")
        #expect(MaintenanceSettingsCopy.memoryDisclosure(bundle: chinese)
            == "内核报告的整个 Clipy 进程用量。RSS 表示当前驻留内存，进程内存占用表示系统记入此进程的内存，峰值为本次启动以来的最高驻留用量。这些值包括应用和框架的运行开销，并非仅剪贴板内容或缓存。")
    }

    @Test("Backup explains sensitive retained content and reports distinct recoveries")
    func backupCopy() throws {
        let english = try bundle("en")
        let chinese = try bundle("zh-Hans")
        #expect(MaintenanceSettingsCopy.text("Back Up History…", bundle: chinese) == "备份历史记录…")
        #expect(MaintenanceSettingsCopy.backupDisclosure(bundle: english).contains("original content and revisions"))
        #expect(MaintenanceSettingsCopy.backupDisclosure(bundle: english).contains("not encrypted"))
        #expect(MaintenanceSettingsCopy.backupDisclosure(bundle: chinese).contains("未经加密"))
        #expect(MaintenanceSettingsCopy.backupDisclosure(bundle: chinese).contains("不支持恢复备份"))
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
