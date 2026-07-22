import SwiftUI

/// Clipy menu-bar agent — step-0 scaffold entry point.
///
/// The real composition root lands at roadmap step 9b (docs/roadmap/06-clipyapp.md):
/// ClipyApp is the sole composition root — concrete construction, lifecycle, paste
/// orchestration (`ClipboardHistory.pastePayload(for:)` → `PasteboardAdapter.write`),
/// and dependency injection. It owns paste orchestration, never Domain decisions, and
/// holds no duplicate persistence path (docs/01-architecture.md §2, §8).
@main
struct ClipyAppMain: App {
    var body: some Scene {
        WindowGroup {
            Text("Clipy — scaffold")
        }
    }
}
