/// PanelAppearanceSettings.swift — the panel's presentation preferences
/// (row density, preview auto-open, preview side), the
/// panel-chrome half of the Settings consolidation surface
/// (docs/v2/V2-07-ux.md §6).
///
/// These are framework-neutral immutable snapshots with product defaults,
/// not policy: every UserDefaults read fails open to the default value, so
/// a missing or unrecognized persisted entry can never break the panel.
///
/// The types are public because they are the configuration vocabulary of the
/// public `HistoryPanelView` seam: the ClipyApp composition root loads one
/// snapshot from UserDefaults and passes it to the panel, and the Settings
/// appearance tab reads and stores the same values.
import Foundation

/// The history-row density: `compact` trades the second snippet line and
/// thumbnail size for more rows per panel height; `comfortable` is the
/// product default (today's row layout).
public enum HistoryRowDensity: String, CaseIterable, Sendable {
    case compact
    case comfortable
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
    public static let rowDensityDefaultsKey = "clipy.appearance.rowDensity"
    public static let previewAutoOpenDefaultsKey =
        "clipy.appearance.previewAutoOpen"
    public static let previewSideDefaultsKey = "clipy.appearance.previewSide"

    public var rowDensity: HistoryRowDensity
    public var isPreviewAutoOpenEnabled: Bool
    public var previewSide: PreviewSidePreference

    public init(
        rowDensity: HistoryRowDensity = .comfortable,
        isPreviewAutoOpenEnabled: Bool = true,
        previewSide: PreviewSidePreference = .automatic
    ) {
        self.rowDensity = rowDensity
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

    /// Persists the snapshot under the three keys above.
    public func store(to defaults: UserDefaults) {
        defaults.set(rowDensity.rawValue, forKey: Self.rowDensityDefaultsKey)
        defaults.set(
            isPreviewAutoOpenEnabled,
            forKey: Self.previewAutoOpenDefaultsKey
        )
        defaults.set(previewSide.rawValue, forKey: Self.previewSideDefaultsKey)
    }
}
