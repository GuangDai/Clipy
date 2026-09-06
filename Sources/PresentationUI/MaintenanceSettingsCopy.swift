import Foundation

internal enum MaintenanceSettingsCopy {
    static var bundle: Bundle { .module }

    static func text(_ english: String, bundle: Bundle = .module) -> String {
        bundle.localizedString(forKey: english, value: english, table: "MaintenanceSettings")
    }

    static func logicalDisclosure(bundle: Bundle = .module) -> String {
        text("Originals and retained revisions, excluding database and filesystem overhead.", bundle: bundle)
    }

    static func folderDisclosure(bundle: Bundle = .module) -> String {
        text(
            "Approximate allocated size of all files in this folder, including hidden files "
                + "and any other data stored here. Linked files and folders are excluded. "
                + "Live writes and shared disk blocks can affect this estimate.",
            bundle: bundle
        )
    }

    static func cacheDisclosure(bundle: Bundle = .module) -> String {
        text(
            "Thumbnail and preview results are retained in memory. This version has no derived disk cache.",
            bundle: bundle
        )
    }

    static func memoryDisclosure(bundle: Bundle = .module) -> String {
        text(
            "Kernel readings for the whole Clipy process. RSS is currently resident memory; "
                + "footprint is memory charged to the process. Peak RSS is since launch. "
                + "These values include app and framework work, not just clipboard content or caches.",
            bundle: bundle
        )
    }
}
