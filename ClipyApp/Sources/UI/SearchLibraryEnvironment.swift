import SwiftUI

private struct SearchHistoryStoreKey: EnvironmentKey {
    static let defaultValue: SearchHistoryStore? = nil
}

private struct OpenSearchSavingSettingsKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    /// One composition-owned preference store is shared by the floating
    /// panel, the History workspace, and search-saving settings.
    var searchHistoryStore: SearchHistoryStore? {
        get { self[SearchHistoryStoreKey.self] }
        set { self[SearchHistoryStoreKey.self] = newValue }
    }

    /// Non-activating panel roots supply their existing native activation
    /// before opening Settings. A regular Settings scene uses openSettings.
    var openSearchSavingSettings: (@MainActor () -> Void)? {
        get { self[OpenSearchSavingSettingsKey.self] }
        set { self[OpenSearchSavingSettingsKey.self] = newValue }
    }
}
