/// ClipyAppMain.swift — the @main entry point: the LSUIElement menu-bar
/// agent shape (set in project.yml — no Dock icon), the Settings scene, and
/// the scene-level wiring to the AppDelegate-owned surfaces.
/// Owning spec: docs/01-architecture.md §2 (composition-root row) and §6
/// (main actor owns views and window behavior); paste wiring lives in
/// AppComposition (01 §5.6); roadmap docs/roadmap/06-clipyapp.md (step 9b).
///
/// Maccy replication note: the browsing surface is NO LONGER a SwiftUI
/// `MenuBarExtra` window — a menu-bar-extra window cannot be summoned or
/// positioned programmatically, so the app follows Maccy's
/// `MaccyApp.swift` model instead: the AppDelegate owns an AppKit
/// `NSStatusItem` + floating `NSPanel` + Carbon hotkey (⇧⌘C), and the only
/// remaining scenes are `Settings` plus a hidden `MenuBarExtra` filler that
/// satisfies SwiftUI's at-least-one-scene requirement.
import AppKit
import HistoryCore
import PresentationUI
import SwiftUI

/// Clipy itself — the composition root's user-facing shell.
@main
struct ClipyAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Hidden scene filler (Maccy's MaccyApp pattern): the REAL
        // status-bar icon is the delegate's `NSStatusItem`, because only an
        // AppKit status item can toggle the floating panel at the icon's
        // frame. `isInserted: false` keeps this MenuBarExtra invisible.
        MenuBarExtra("", isInserted: .constant(false)) {
            EmptyView()
        }

        Settings {
            SettingsRootView(appDelegate: appDelegate)
        }
    }
}

/// The Settings scene body: the real settings once the composition exists,
/// `EmptyView` until then (the store must open before any view state exists
/// to drive retention edits). Owns the panel-position preference via
/// `@AppStorage` — the same defaults key `AppDelegate` reads at summon time
/// (`AppDelegate.popupPositionDefaultsKey`).
private struct SettingsRootView: View {
    let appDelegate: AppDelegate

    @AppStorage(AppDelegate.popupPositionDefaultsKey)
    private var panelPosition: PopupPositionMode = .cursor
    @State private var isRecordingSummonShortcut = false

    var body: some View {
        if let composition = appDelegate.composition {
            ClipySettingsView(
                viewState: composition.viewState,
                launchAtLogin: appDelegate.launchAtLoginBinding(),
                summonShortcut: appDelegate.summonShortcutBinding {
                    isRecordingSummonShortcut = true
                },
                popupPosition: $panelPosition
            )
            .sheet(isPresented: $isRecordingSummonShortcut) {
                SummonShortcutRecorderView { chord in
                    appDelegate.changeSummonShortcut(to: chord)
                }
            }
        } else {
            EmptyView()
        }
    }
}
