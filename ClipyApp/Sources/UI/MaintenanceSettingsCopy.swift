import Foundation

internal enum MaintenanceSettingsCopy {
    static var bundle: Bundle { .main }

    static func text(_ english: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: english, value: english, table: "MaintenanceSettings")
    }

    static func backupDisclosure(bundle: Bundle = .main) -> String {
        text(
            "Backups contain all retained history, including original content and revisions. "
                + "They may contain passwords and other sensitive information and are not encrypted. "
                + "Choose a private location. This version does not restore backups.",
            bundle: bundle
        )
    }

    static func backupStatus(
        _ outcome: HistoryBackupSettingsModel.Outcome, bundle: Bundle = .main
    ) -> String {
        switch outcome {
        case .cancelled:
            text("Backup cancelled.", bundle: bundle)
        case .completed(let itemCount):
            String(
                format: text("Backup complete. Retained items: %lld.", bundle: bundle),
                Int64(itemCount)
            )
        case .failed(.invalidDestination), .failed(.destinationAlreadyExists):
            text("Choose a new backup folder. Existing files and folders cannot be replaced.", bundle: bundle)
        case .failed(.destinationUnavailable):
            text("The backup location is unavailable. Choose another location and try again.", bundle: bundle)
        case .failed(.writeFailed):
            text("Backup could not be saved. Check available disk space and folder permissions, then try again.", bundle: bundle)
        case .sourceFailed:
            text("History could not be read for backup. Try again after reopening Clipy.", bundle: bundle)
        }
    }

    static func logicalDisclosure(bundle: Bundle = .main) -> String {
        text("Originals and retained revisions, excluding database and filesystem overhead.", bundle: bundle)
    }

    static func folderDisclosure(bundle: Bundle = .main) -> String {
        text(
            "Approximate allocated size of all files in this folder, including hidden files "
                + "and any other data stored here. Linked files and folders are excluded. "
                + "Live writes and shared disk blocks can affect this estimate.",
            bundle: bundle
        )
    }

    static func cacheDisclosure(bundle: Bundle = .main) -> String {
        text(
            "Thumbnail and preview results are retained in memory. This version has no derived disk cache.",
            bundle: bundle
        )
    }

    static func memoryDisclosure(bundle: Bundle = .main) -> String {
        text(
            "Kernel readings for the whole Clipy process. RSS is currently resident memory; "
                + "footprint is memory charged to the process. Peak RSS is since launch. "
                + "These values include app and framework work, not just clipboard content or caches.",
            bundle: bundle
        )
    }
}
