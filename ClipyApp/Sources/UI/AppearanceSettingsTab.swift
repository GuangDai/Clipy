import Foundation
import HistoryCore
import SwiftUI

// MARK: Appearance

/// Appearance tab: the panel-chrome half of the Settings consolidation
/// surface (`V2-07` §6). Placement rides the composition root's optional
/// `PopupPositionMode` binding; row density, snippet line count, font size,
/// and preview auto-open persist through `@AppStorage` under the
/// `PanelAppearanceSettings` keys with the same product defaults its
/// `load(from:)` fails open to, so an untouched control and an absent
/// defaults entry always agree. The preview, row-density, and typography
/// preferences apply live; only panel position and the panel-size reset
/// apply the next time the panel opens, which the Panel section footer
/// discloses. The floating preview's side is chosen from screen geometry
/// (PopupPositionGeometry.floatingPreviewFrame) — it has no control here.
struct AppearanceSettingsTab: View {

    private let popupPosition: Binding<PopupPositionMode>?

    /// `@AppStorage` reads and writes the persisted raw values; the enum
    /// conversion happens at the control's tag, keeping this view a pure
    /// projection of the same UserDefaults keys `PanelAppearanceSettings`
    /// owns. The wrapped defaults below are the documented product defaults.
    @AppStorage(PanelAppearanceSettings.rowDensityDefaultsKey)
    private var rowDensity: HistoryRowDensity = PanelAppearanceSettings().rowDensity
    @AppStorage(PanelAppearanceSettings.snippetLineCountDefaultsKey)
    private var snippetLineCount: HistorySnippetLineCount = .automatic
    @AppStorage(PanelAppearanceSettings.rowFontSizeDefaultsKey)
    private var rowFontSize: HistoryRowFontSize = .medium
    @AppStorage(PanelAppearanceSettings.previewAutoOpenDefaultsKey)
    private var isPreviewAutoOpenEnabled = true

    @State private var isShowingTextAppearance = true
    @State private var isShowingPreviewOptions = false
    @State private var hasResetPanelSize = false
    @AppStorage(PreviewTextSettings.maximumCharactersKey)
    private var previewMaximumCharacters = PreviewTextSettings.defaultMaximumCharacters
    @AppStorage(PreviewTextSettings.isLengthLimitedKey)
    private var isPreviewTextLengthLimited = true
    @AppStorage(PanelGeometry.floatingPreviewGapDefaultsKey)
    private var previewGap = Double(PanelGeometry.floatingPreviewGap)

    init(popupPosition: Binding<PopupPositionMode>?) {
        self.popupPosition = popupPosition
    }

    var body: some View {
        Form {
            Section {
                sampleRow
                SettingsFieldLayout {
                    Text(SettingsCopy.text("Row density"))
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 6) {
                        HStack(spacing: 0) {
                            ForEach(HistoryRowDensity.allCases, id: \.self) { density in
                                densitySample(density)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .accessibilityHidden(true)
                        Picker(SettingsCopy.text("Row density"), selection: $rowDensity) {
                            ForEach(HistoryRowDensity.allCases, id: \.self) { density in
                                Text(rowDensityLabel(density)).tag(density)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("clipy.settings.appearance.row-density")
                    }
                }
                DisclosureGroup(
                    AdaptiveSettingsCopy.text("Text Appearance"),
                    isExpanded: $isShowingTextAppearance
                ) {
                    SettingsFieldLayout {
                        Text(SettingsCopy.text("Text lines"))
                            .fixedSize(horizontal: false, vertical: true)
                        Picker(SettingsCopy.text("Text lines"), selection: $snippetLineCount) {
                            ForEach(HistorySnippetLineCount.allCases, id: \.self) { count in
                                Text(snippetLineCountLabel(count)).tag(count)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("clipy.settings.appearance.snippet-lines")
                    }
                    SettingsFieldLayout {
                        Text(SettingsCopy.text("Font size"))
                            .fixedSize(horizontal: false, vertical: true)
                        Picker(SettingsCopy.text("Font size"), selection: $rowFontSize) {
                            ForEach(HistoryRowFontSize.allCases, id: \.self) { size in
                                Text(rowFontSizeLabel(size)).tag(size)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityIdentifier("clipy.settings.appearance.font-size")
                    }
                }
                .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.settings.appearance.text-appearance"))
            } header: {
                Text(SettingsCopy.text("List"))
            }
            Section {
                previewPlacementSample
                Toggle(
                    SettingsCopy.text("Open preview automatically"),
                    isOn: $isPreviewAutoOpenEnabled
                )
                .accessibilityIdentifier("clipy.settings.appearance.preview-auto-open")
                SettingsFieldLayout {
                    Label(SettingsCopy.text("Panel gap"), systemImage: "arrow.left.and.right")
                    TextField("", value: Binding(
                        get: { previewGap },
                        set: { previewGap = $0.isFinite ? max(0, $0) : Double(PanelGeometry.floatingPreviewGap) }
                    ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 64, idealWidth: 80, maxWidth: 120)
                        .accessibilityLabel(AdaptiveSettingsCopy.text("Preferred panel gap (pt)"))
                        .accessibilityIdentifier("clipy.settings.preview.panel-gap")
                        .help(AdaptiveSettingsCopy.text("The preview opens beside the panel. A gap of zero joins their edges. Changes apply immediately; available screen space may reduce the gap."))
                }
                DisclosureGroup(AdaptiveSettingsCopy.text("Advanced Preview"), isExpanded: $isShowingPreviewOptions) {
                    Toggle(AdaptiveSettingsCopy.text("Show complete text"), isOn: Binding(
                        get: { !isPreviewTextLengthLimited },
                        set: { isPreviewTextLengthLimited = !$0 }
                    ))
                    .accessibilityIdentifier("clipy.settings.preview.complete-text")
                    if isPreviewTextLengthLimited {
                        SettingsFieldLayout {
                            Text(AdaptiveSettingsCopy.text("Preview characters"))
                            TextField("", value: Binding(
                                get: { previewMaximumCharacters },
                                set: { previewMaximumCharacters = max(1, $0) }
                            ), format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(minWidth: 96, idealWidth: 120, maxWidth: 180)
                                .accessibilityLabel(AdaptiveSettingsCopy.text("Preview characters"))
                                .accessibilityIdentifier("clipy.settings.preview.character-count")
                        }
                    }
                    Text(AdaptiveSettingsCopy.text("Complete text uses more memory and may take longer to prepare. Text is laid out as you scroll. Copying and search always use their own content settings."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.settings.appearance.advanced-preview"))
                Button(SettingsCopy.text("Reset Preview Settings")) {
                    isPreviewAutoOpenEnabled = true
                    previewMaximumCharacters = PreviewTextSettings.defaultMaximumCharacters
                    isPreviewTextLengthLimited = true
                    previewGap = Double(PanelGeometry.floatingPreviewGap)
                }
                .accessibilityIdentifier("clipy.settings.preview.reset")
            } header: {
                Text(AdaptiveSettingsCopy.text("Preview"))
            }
            Section {
                if let popupPosition {
                    Picker(SettingsCopy.text("Panel position"), selection: popupPosition) {
                        ForEach(PopupPositionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("clipy.settings.appearance.panel-position")
                }
                Button(SettingsCopy.text("Reset Panel Size to Default")) {
                    Self.resetPersistedPanelSize()
                    hasResetPanelSize = true
                }
                .accessibilityIdentifier("clipy.settings.appearance.reset-panel-size")
                if hasResetPanelSize {
                    SettingStatusView(status: .success(SettingsCopy.text(
                        "Panel size reset. Reopen the panel to use the default size."
                    )))
                    .accessibilityIdentifier("clipy.settings.appearance.panel-size-status")
                }
            } header: {
                Text(SettingsCopy.text("Panel"))
            } footer: {
                Text(SettingsCopy.text("Panel position and size changes apply the next time the panel opens."))
            }
        }
        .formStyle(.grouped)
    }

    /// V2-11: ordinary rows have a title, never a fabricated body excerpt.
    /// The sample uses the same metrics and configured title-line allowance
    /// as HistoryRowView, so its size changes with the actual preference.
    private var sampleRow: some View {
        VStack(spacing: 0) {
            sampleHistoryRow(
                SettingsCopy.text("Reading notes — collect useful ideas, save a link, and pick up where you left off."),
                symbol: "text.alignleft", selected: true
            )
            sampleHistoryRow("https://example.org/reading-list", symbol: "link")
            sampleHistoryRow(SettingsCopy.text("Weekend itinerary.pdf"), symbol: "doc")
        }
        .padding(6)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SettingsCopy.text("List sample"))
        .accessibilityIdentifier("clipy.settings.appearance.list-sample")
    }

    private func sampleHistoryRow(
        _ title: String, symbol: String, selected: Bool = false
    ) -> some View {
        let lines = snippetLineCount.baseLineLimit(density: rowDensity)
        let descriptor = PanelContentFit.RowDescriptor(
            isImageRow: false, titleLineCount: lines, snippetLineCount: 0
        )
        return HStack(spacing: PanelTheme.spacingSmall) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: PanelTheme.thumbnailSize(for: rowDensity))
            Text(title)
                .font(PanelTheme.titleFont(for: rowFontSize))
                .lineLimit(lines)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, PanelTheme.spacingXSmall)
        .frame(height: PanelContentFit.rowHeight(
            descriptor, density: rowDensity, fontSize: rowFontSize
        ))
        .background {
            RoundedRectangle(cornerRadius: PanelTheme.cornerRadiusSmall)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        }
    }

    /// Keep the picker itself native. Its paired diagrams compare actual
    /// density spacing without relying on custom NSSegmentedControl content.
    private func densitySample(_ density: HistoryRowDensity) -> some View {
        VStack(spacing: density == .compact ? 3 : 7) {
            ForEach(0..<3) { _ in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).frame(width: 5, height: 5)
                    Capsule().frame(width: 42, height: 3)
                }
            }
        }
        .foregroundStyle(rowDensity == density ? Color.accentColor : Color.secondary)
        .frame(height: 30)
    }

    /// A small scale drawing expresses the relationship between the windows.
    /// Only the drawing scales to fit; the persisted gap stays unbounded.
    private var previewPlacementSample: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let gap = CGFloat(previewGap.isFinite ? max(0, previewGap) : 2)
                let scale = min(1, max(0, geometry.size.width) / (220 + gap))
                HStack(alignment: .top, spacing: gap * scale) {
                    miniatureWindow(isPreview: false)
                        .frame(width: 120 * scale, height: 60)
                    miniatureWindow(isPreview: true)
                        .frame(width: 100 * scale, height: 48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(height: 60)
            Label {
                Text("\(previewGap, format: .number) pt")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "arrow.left.and.right")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SettingsCopy.text("Panel gap"))
        .accessibilityValue(Text("\(previewGap, format: .number) pt"))
        .accessibilityIdentifier("clipy.settings.appearance.gap-sample")
    }

    private func miniatureWindow(isPreview: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !isPreview {
                HStack(spacing: 3) {
                    Image(systemName: "magnifyingglass").font(.system(size: 6))
                    Capsule().frame(maxWidth: .infinity).frame(height: 2)
                }
                .padding(.bottom, 2)
            }
            ForEach(0..<(isPreview ? 3 : 4), id: \.self) { index in
                Capsule()
                    .fill(!isPreview && index == 0 ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(height: isPreview ? 2 : 4)
                    .padding(.trailing, isPreview && index == 2 ? 16 : 0)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(.tertiary, lineWidth: 1)
        }
        .clipped()
    }

    private func rowDensityLabel(_ density: HistoryRowDensity) -> String {
        switch density {
        case .compact: return SettingsCopy.text("Compact")
        case .comfortable: return SettingsCopy.text("Comfortable")
        }
    }

    /// Auto stays short — a four-segment "Automatic" risks truncation; the
    /// explicit cases label with their raw counts.
    private func snippetLineCountLabel(_ count: HistorySnippetLineCount) -> String {
        switch count {
        case .automatic: return SettingsCopy.text("Auto")
        case .one: return LocalizedCountPresentation.number(1, locale: .current)
        case .two: return LocalizedCountPresentation.number(2, locale: .current)
        case .three: return LocalizedCountPresentation.number(3, locale: .current)
        }
    }

    private func rowFontSizeLabel(_ size: HistoryRowFontSize) -> String {
        switch size {
        case .small: return SettingsCopy.text("Small")
        case .medium: return SettingsCopy.text("Medium")
        case .large: return SettingsCopy.text("Large")
        }
    }

    /// Removing both keys returns the next panel open to the geometry
    /// defaults: `PanelGeometry.persistedSize(from:)` falls back per key,
    /// so a deleted entry is indistinguishable from a fresh install.
    private static func resetPersistedPanelSize() {
        let defaults = UserDefaults.standard
        defaults.removeObject(
            forKey: PanelGeometry.panelContentWidthDefaultsKey
        )
        defaults.removeObject(forKey: PanelGeometry.panelHeightDefaultsKey)
    }
}
