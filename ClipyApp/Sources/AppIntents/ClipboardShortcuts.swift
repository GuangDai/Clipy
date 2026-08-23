/// The complete X.7 Shortcuts catalog. Each phrase names the application as
/// required by AppShortcutsProvider; no additional hidden intent is surfaced.
import AppIntents

struct ClipboardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchHistoryIntent(),
            phrases: ["Search \(.applicationName) clipboard history"],
            shortTitle: "Search Clipboard",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: GetItemDetailsIntent(),
            phrases: ["Get an item from \(.applicationName)"],
            shortTitle: "Clipboard Details",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: PasteItemIntent(),
            phrases: ["Copy an item from \(.applicationName)"],
            shortTitle: "Copy Clipboard Item",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: PinItemIntent(),
            phrases: ["Pin an item in \(.applicationName)"],
            shortTitle: "Pin Clipboard Item",
            systemImageName: "pin"
        )
        AppShortcut(
            intent: UnpinItemIntent(),
            phrases: ["Unpin an item in \(.applicationName)"],
            shortTitle: "Unpin Clipboard Item",
            systemImageName: "pin.slash"
        )
        AppShortcut(
            intent: RemoveItemIntent(),
            phrases: ["Remove an item from \(.applicationName)"],
            shortTitle: "Remove Clipboard Item",
            systemImageName: "trash"
        )
    }
}
