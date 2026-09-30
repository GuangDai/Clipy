#if DEBUG
import Foundation

/// Scoped running-app diagnosis. The journey precreates its own temporary
/// file; only fixed event names and window/phase facts may be recorded here.
@MainActor
func recordPreviewLifecycle(_ event: String) {
    let environment = ProcessInfo.processInfo.environment
    guard environment["CLIPY_RUNNING_UI_TEST"] == "1",
          let path = environment["CLIPY_FILE_PREVIEW_LIFECYCLE_PATH"],
          let file = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return }
    defer { try? file.close() }
    do {
        _ = try file.seekToEnd()
        try file.write(contentsOf: Data(("\(ProcessInfo.processInfo.systemUptime) \(event)\n").utf8))
    } catch {
        // Diagnostic I/O cannot change file preview or confirmation behavior.
    }
}
#endif
