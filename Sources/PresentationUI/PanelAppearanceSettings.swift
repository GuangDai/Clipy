/// PanelAppearanceSettings.swift — the panel's presentation preferences
/// (row density, preview auto-open, preview side, and the row-typography
/// pair of snippet line count and font size), the panel-chrome half of
/// the Settings consolidation surface (docs/v2/V2-07-ux.md §6).
///
/// These are framework-neutral immutable snapshots with product defaults,
/// not policy: every UserDefaults read fails open to the default value, so
/// a missing or unrecognized persisted entry can never break the panel.
///
/// Access split (GOV-3 contraction; docs/v2/V2-07-ux.md §6): the snapshot
/// type, its `load(from:)` seam, `previewSide`, and the default `init()` the
/// public `HistoryPanelView` initializer's default argument evaluates in the
/// caller's module are public — that is exactly the configuration vocabulary
/// the ClipyApp composition root names. The density/auto-open/typography
/// half of the vocabulary is package: the Settings appearance tab that
/// reads, edits, and stores it lives in this module.
import Foundation

/// The history-row density: `compact` trades thumbnail size, vertical
/// padding, and — under the default `.automatic` snippet-line setting —
/// the second snippet line for more rows per panel height; `comfortable`
/// is the product default (today's row layout). Package (GOV-3): the
/// density consumers — the Settings appearance tab, the list/row views,
/// the theme metrics — are all in-package.
///
/// The snippet line count itself is the separate `HistorySnippetLineCount`
/// preference (orthogonal): its `.automatic` case resolves through density
/// (compact 1, comfortable 2 — the shipped mapping), while an explicit
/// 1/2/3 overrides density entirely.
package enum HistoryRowDensity: String, CaseIterable, Sendable {
    case compact
    case comfortable
}

/// The row's summary/snippet line-count preference (Settings ▸ Appearance).
/// `.automatic` (the product default) defers to the row density — compact 1
/// line, comfortable 2 lines, exactly the retired
/// `PanelTheme.snippetLineLimit(for:)` mapping — so the shipped defaults
/// reproduce the shipped layout at either density. An explicit
/// `.one`/`.two`/`.three` overrides density entirely (a compact user who
/// picks 3 gets 3). Wide-presentation breathing adds one line above the
/// resolved base, hard capped at three — the pure rule is
/// `HistoryRowLayout.effectiveSnippetLineLimit(setting:density:isWide:)`.
/// Package (GOV-3), same access split as `HistoryRowDensity`. Case order is
/// the Settings picker's segment order: Auto first.
package enum HistorySnippetLineCount: String, CaseIterable, Sendable {
    case automatic = "automatic"
    case one = "1"
    case two = "2"
    case three = "3"

    /// The density-resolved base line limit. `.automatic` reproduces the
    /// shipped density mapping (compact 1, comfortable 2); the explicit
    /// cases carry their literal count regardless of density.
    package func baseLineLimit(density: HistoryRowDensity) -> Int {
        switch self {
        case .automatic:
            switch density {
            case .compact: return 1
            case .comfortable: return 2
            }
        case .one: return 1
        case .two: return 2
        case .three: return 3
        }
    }
}

/// The row typography scale (Settings ▸ Appearance). `medium` reproduces
/// the shipped row fonts exactly — the pin lives in `PanelTheme`'s
/// per-line-role mappings; `small` and `large` step one text-style rung
/// down and up. Package (GOV-3), same access split as `HistoryRowDensity`.
package enum HistoryRowFontSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large
}

/// The preferred preview-pane side. `automatic` keeps the composition
/// root's screen-geometry choice (today's `PreviewPlacement` behavior);
/// `leading` and `trailing` pin the pane to one side.
public enum PreviewSidePreference: String, CaseIterable, Sendable {
    case automatic
    case leading
    case trailing
}

/// One immutable panel-appearance snapshot plus its UserDefaults
/// persistence. Each key is independent: an absent or unrecognized value
/// falls back to that preference's product default, never to a neighbor's.
///
/// The retired preview-width-stop preference lived under
/// "clipy.appearance.previewWidth"; the free-drag divider replaced it with
/// `PanelGeometry.previewColumnWidthDefaultsKey`. A leftover value in an
/// upgraded user's defaults is simply never read, so no migration is needed.
public struct PanelAppearanceSettings: Equatable, Sendable {
    /// Package (GOV-3): `load(from:)` below is the only cross-module reader
    /// of these keys and the Settings tab stores through the same module —
    /// ClipyApp never names a raw key.
    package static let rowDensityDefaultsKey = "clipy.appearance.rowDensity"
    package static let snippetLineCountDefaultsKey =
        "clipy.appearance.snippetLineCount"
    package static let rowFontSizeDefaultsKey =
        "clipy.appearance.rowFontSize"
    package static let previewAutoOpenDefaultsKey =
        "clipy.appearance.previewAutoOpen"
    package static let previewSideDefaultsKey = "clipy.appearance.previewSide"

    package var rowDensity: HistoryRowDensity
    package var snippetLineCount: HistorySnippetLineCount
    package var rowFontSize: HistoryRowFontSize
    package var isPreviewAutoOpenEnabled: Bool
    public var previewSide: PreviewSidePreference

    /// The public default snapshot. The public `HistoryPanelView`
    /// initializer's `appearance: PanelAppearanceSettings = ...` default
    /// argument is evaluated in the caller's module, so the seam ClipyApp
    /// resolves through must be public even though the full vocabulary init
    /// below is package (the split-init precedent of
    /// `HistoryPanelView.swift`'s public/package initializers).
    public init() {
        self.init(
            rowDensity: .comfortable,
            snippetLineCount: .automatic,
            rowFontSize: .medium,
            isPreviewAutoOpenEnabled: true,
            previewSide: .automatic
        )
    }

    /// The full vocabulary init. Package (GOV-3): density, typography, and
    /// auto-open are Settings-tab vocabulary; the literals mirror the
    /// package defaults and the public `init()` above.
    package init(
        rowDensity: HistoryRowDensity = .comfortable,
        snippetLineCount: HistorySnippetLineCount = .automatic,
        rowFontSize: HistoryRowFontSize = .medium,
        isPreviewAutoOpenEnabled: Bool = true,
        previewSide: PreviewSidePreference = .automatic
    ) {
        self.rowDensity = rowDensity
        self.snippetLineCount = snippetLineCount
        self.rowFontSize = rowFontSize
        self.isPreviewAutoOpenEnabled = isPreviewAutoOpenEnabled
        self.previewSide = previewSide
    }

    /// Loads the persisted preferences. Raw strings no case recognizes
    /// (written by an older or newer build) and non-Bool toggle values read
    /// as the product defaults.
    public static func load(
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
        if let rawSide = defaults.string(forKey: previewSideDefaultsKey),
           let side = PreviewSidePreference(rawValue: rawSide) {
            settings.previewSide = side
        }
        return settings
    }

    /// Persists the snapshot under the five keys above. Package (GOV-3):
    /// the Settings appearance tab owns the store; the composition root only
    /// `load(from:)`s.
    package func store(to defaults: UserDefaults) {
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
        defaults.set(previewSide.rawValue, forKey: Self.previewSideDefaultsKey)
    }
}
