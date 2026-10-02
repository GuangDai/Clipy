import Observation

/// Copy feedback belongs to the persistent Settings workspace. The actual
/// History read and pasteboard write remain in AppComposition's one copy slot.
@MainActor @Observable
final class HistoryWorkspaceCopyState {
    var isCopying = false
    var status: SettingStatus?
    var cancel: () -> Void = {}
}
