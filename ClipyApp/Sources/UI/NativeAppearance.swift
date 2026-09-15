import AppKit
import SwiftUI

/// AppKit owns appearance for every window, sheet and native text control.
/// System follows macOS automatically; unknown saved choices do the same.
enum NativeAppearance: String, CaseIterable {
    case system, light, dark

    static let defaultsKey = "clipy.appearance.colorScheme"

    static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var title: String {
        let key = switch self {
        case .system: "Follow macOS"
        case .light: "Light"
        case .dark: "Dark"
        }
        return NativeAppearanceCopy.text(key)
    }
}

enum NativeAppearanceCopy {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "NativeAppearance", bundle: .main, comment: "")
    }
}

/// Solid native content background shared by the summoned panel and preview.
/// textBackgroundColor is white in light appearance and adapts in dark mode;
/// no material blends desktop colors through these reading surfaces.
struct NativePanelBackground: View {
    var body: some View {
        Color(nsColor: .textBackgroundColor)
    }
}
