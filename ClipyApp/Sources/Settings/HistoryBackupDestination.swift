import AppKit

/// AppKit chooses a new backup directory. History creates it exclusively;
/// accepting the save panel never authorizes replacing an existing backup.
@MainActor
enum HistoryBackupDestination {
    static func choose() async -> URL? {
        guard !Task.isCancelled else { return nil }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = copy("Back Up History")
        panel.prompt = copy("Back Up")
        panel.message = copy("Choose a name for a new backup folder. Existing files and folders cannot be replaced.")
        panel.nameFieldStringValue = copy("Clipy Backup")
        let response = await withTaskCancellationHandler {
            guard !Task.isCancelled else { return NSApplication.ModalResponse.cancel }
            if let window = NSApp.keyWindow {
                return await panel.beginSheetModal(for: window)
            }
            return await panel.begin()
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
        panel.orderOut(nil)
        guard !Task.isCancelled, response == .OK else { return nil }
        return panel.url
    }

    static func reveal(_ directory: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private static func copy(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "HistoryBackup")
    }
}
