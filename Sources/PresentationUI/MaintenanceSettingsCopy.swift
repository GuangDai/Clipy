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
}
