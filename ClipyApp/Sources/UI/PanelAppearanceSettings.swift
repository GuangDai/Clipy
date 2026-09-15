/// PanelAppearanceSettings.swift — the panel's presentation preferences
/// (row density, preview auto-open, and the row-typography pair of snippet
/// line count and font size), the panel-chrome half of the Settings
/// consolidation surface (docs/v2/V2-07-ux.md §6).
///
/// These are framework-neutral immutable snapshots with product defaults,
/// not policy: every UserDefaults read fails open to the default value, so
/// a missing or unrecognized persisted entry can never break the panel.
///
/// Access split (GOV-3 contraction; docs/v2/V2-07-ux.md §6): the snapshot
/// type, its `load(from:)` seam, and the default `init()` the public
/// `HistoryPanelView` initializer's default argument evaluates in the
/// caller's module are public — that is exactly the configuration vocabulary
/// the ClipyApp composition root names. The density/auto-open/typography
/// half of the vocabulary is package: the Settings appearance tab that
/// reads, edits, and stores it lives in this module.
import Foundation

/// The history-row density: `compact` trades thumbnail size, vertical
/// padding, and — under the default `.automatic` snippet-line setting —
/// the second snippet line for more rows per panel height. `compact`
/// is the product default; `comfortable` adds breathing room. Package (GOV-3): the
/// density consumers — the Settings appearance tab, the list/row views,
/// the theme metrics — are all in-package.
///
/// The snippet line count itself is the separate `HistorySnippetLineCount`
/// preference (orthogonal): its `.automatic` case resolves through density
/// (compact 1, comfortable 2 — the shipped mapping), while an explicit
/// count overrides density entirely.
enum HistoryRowDensity: String, CaseIterable, Sendable {
    case compact
    case comfortable
}

/// A user-entered line count, or the density's automatic allowance.
/// Strings keep @AppStorage and the existing persisted preferences in sync.
struct HistorySnippetLineCount: RawRepresentable, Hashable, Sendable {
    static let allowedValues = 1...100
    let count: Int?

    static let automatic = Self(count: nil)
    static let one = Self(count: 1)
    static let two = Self(count: 2)
    static let three = Self(count: 3)

    private init(count: Int?) { self.count = count }

    init?(rawValue: String) {
        if rawValue == "automatic" { self = .automatic; return }
        guard let count = Int(rawValue), Self.allowedValues.contains(count) else { return nil }
        self.count = count
    }

    var rawValue: String { count.map(String.init) ?? "automatic" }

    func baseLineLimit(density: HistoryRowDensity) -> Int {
        count ?? (density == .compact ? 1 : 2)
    }
}

/// Actual system-font points, including fractional values. The named values
/// preserve existing callers and stored choices; Settings offers direct input.
struct HistoryRowFontSize: RawRepresentable, Hashable, Sendable {
    static let allowedValues = 1.0...200.0
    let points: Double

    static let small = Self(points: 11)
    static let medium = Self(points: 13)
    static let large = Self(points: 15)

    private init(points: Double) { self.points = points }

    init?(rawValue: String) {
        switch rawValue {
        case "small": self = .small
        case "medium": self = .medium
        case "large": self = .large
        default:
            guard let points = Double(rawValue), points.isFinite,
                  Self.allowedValues.contains(points) else { return nil }
            self.points = points
        }
    }

    var rawValue: String { String(points) }

    /// Supporting row text retains the former 11/12/13pt scale at the
    /// former 11/13/15pt choices, and scales continuously for custom input.
    var snippetPoints: Double { min(points, (points + 11) / 2) }
    var metadataPoints: Double { max(1, points - 2) }
}

/// One immutable panel-appearance snapshot plus its UserDefaults
/// persistence. Each key is independent: an absent or unrecognized value
/// falls back to that preference's product default, never to a neighbor's.
///
/// The retired preview-side preference lived under
/// "clipy.appearance.previewSide" and the retired divider preview width
/// under "clipy.panel.previewColumnWidth"; the floating preview pane
/// replaced both. Leftover values in an upgraded user's defaults are simply
/// never read, so no migration is needed.
struct PanelAppearanceSettings: Equatable, Sendable {
    /// Package (GOV-3): `load(from:)` below is the only cross-module reader
    /// of these keys and the Settings tab stores through the same module —
    /// ClipyApp never names a raw key.
    static let rowDensityDefaultsKey = "clipy.appearance.rowDensity"
    static let snippetLineCountDefaultsKey =
        "clipy.appearance.snippetLineCount"
    static let rowFontSizeDefaultsKey =
        "clipy.appearance.rowFontSize"
    static let previewAutoOpenDefaultsKey =
        "clipy.appearance.previewAutoOpen"

    var rowDensity: HistoryRowDensity
    var snippetLineCount: HistorySnippetLineCount
    var rowFontSize: HistoryRowFontSize
    var isPreviewAutoOpenEnabled: Bool

    /// The public default snapshot. The public `HistoryPanelView`
    /// initializer's `appearance: PanelAppearanceSettings = ...` default
    /// argument is evaluated in the caller's module, so the seam ClipyApp
    /// resolves through must be public even though the full vocabulary init
    /// below is package (the split-init precedent of
    /// `HistoryPanelView.swift`'s public/package initializers).
    init() {
        self.init(
            rowDensity: .compact,
            snippetLineCount: .automatic,
            rowFontSize: .medium,
            isPreviewAutoOpenEnabled: true
        )
    }

    /// The full vocabulary init. Package (GOV-3): density, typography, and
    /// auto-open are Settings-tab vocabulary; the literals mirror the
    /// package defaults and the public `init()` above.
    init(
        rowDensity: HistoryRowDensity = .compact,
        snippetLineCount: HistorySnippetLineCount = .automatic,
        rowFontSize: HistoryRowFontSize = .medium,
        isPreviewAutoOpenEnabled: Bool = true
    ) {
        self.rowDensity = rowDensity
        self.snippetLineCount = snippetLineCount
        self.rowFontSize = rowFontSize
        self.isPreviewAutoOpenEnabled = isPreviewAutoOpenEnabled
    }

    /// Loads the persisted preferences. Unrecognized or invalid numeric
    /// values and non-Bool toggle values read as the product defaults.
    static func load(
        from defaults: UserDefaults
    ) -> PanelAppearanceSettings {
        var settings = PanelAppearanceSettings()
        if let rawDensity = defaults.string(forKey: rowDensityDefaultsKey),
           let density = HistoryRowDensity(rawValue: rawDensity) {
            settings.rowDensity = density
        }
        if let rawLineCount = defaults.string(
            forKey: snippetLineCountDefaultsKey
        ),
           let lineCount = HistorySnippetLineCount(rawValue: rawLineCount) {
            settings.snippetLineCount = lineCount
        }
        if let rawFontSize = defaults.string(forKey: rowFontSizeDefaultsKey),
           let fontSize = HistoryRowFontSize(rawValue: rawFontSize) {
            settings.rowFontSize = fontSize
        }
        if let autoOpen = defaults.object(
            forKey: previewAutoOpenDefaultsKey
        ) as? Bool {
            settings.isPreviewAutoOpenEnabled = autoOpen
        }
        return settings
    }

    /// Persists the snapshot under the four keys above. Package (GOV-3):
    /// the Settings appearance tab owns the store; the composition root only
    /// `load(from:)`s.
    func store(to defaults: UserDefaults) {
        defaults.set(rowDensity.rawValue, forKey: Self.rowDensityDefaultsKey)
        defaults.set(
            snippetLineCount.rawValue,
            forKey: Self.snippetLineCountDefaultsKey
        )
        defaults.set(
            rowFontSize.rawValue,
            forKey: Self.rowFontSizeDefaultsKey
        )
        defaults.set(
            isPreviewAutoOpenEnabled,
            forKey: Self.previewAutoOpenDefaultsKey
        )
    }
}
