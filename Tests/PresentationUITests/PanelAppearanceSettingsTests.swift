/// PanelAppearanceSettingsTests — the panel presentation-vocabulary proofs:
/// appearance preferences fail open to their product defaults and round-trip
/// through UserDefaults per case, `PanelGeometry` clamps and persists the
/// user-resizable size and the divider's free-drag preview column width
/// inside their bounds, and the `PanelTheme` density mappings stay pinned
/// to their compact/comfortable literals.
import Foundation
import PresentationUI
import Testing

@Suite("Panel presentation vocabulary")
struct PanelAppearanceSettingsTests {
    @Test("absent UserDefaults keys load the product defaults")
    func absentKeysLoadProductDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = PanelAppearanceSettings.load(from: defaults)

        #expect(settings == PanelAppearanceSettings())
        #expect(settings.rowDensity == .comfortable)
        #expect(settings.isPreviewAutoOpenEnabled)
        #expect(settings.previewSide == .automatic)
    }

    @Test("store→load round-trips every density, side, and toggle")
    func storeLoadRoundTripsEveryCombination() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for density in HistoryRowDensity.allCases {
            for side in PreviewSidePreference.allCases {
                for autoOpen in [true, false] {
                    let settings = PanelAppearanceSettings(
                        rowDensity: density,
                        isPreviewAutoOpenEnabled: autoOpen,
                        previewSide: side
                    )
                    settings.store(to: defaults)
                    #expect(
                        PanelAppearanceSettings.load(from: defaults)
                            == settings
                    )
                }
            }
        }
    }

    @Test("unrecognized persisted values fall back to the product defaults")
    func unknownPersistedValuesFallBackToDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            "dense",
            forKey: PanelAppearanceSettings.rowDensityDefaultsKey
        )
        defaults.set(
            "yes",
            forKey: PanelAppearanceSettings.previewAutoOpenDefaultsKey
        )
        defaults.set(
            "left",
            forKey: PanelAppearanceSettings.previewSideDefaultsKey
        )

        #expect(
            PanelAppearanceSettings.load(from: defaults)
                == PanelAppearanceSettings()
        )
    }

    @Test("content width clamps at, below, and above the resizable bounds")
    func contentWidthClampsIntoBounds() {
        #expect(PanelGeometry.minimumContentWidth == 360)
        #expect(PanelGeometry.maximumContentWidth == 720)
        #expect(PanelGeometry.clampedContentWidth(360) == 360)
        #expect(PanelGeometry.clampedContentWidth(720) == 720)
        #expect(PanelGeometry.clampedContentWidth(100) == 360)
        #expect(PanelGeometry.clampedContentWidth(10_000) == 720)
        #expect(PanelGeometry.clampedContentWidth(400) == PanelGeometry.contentWidth)
    }

    @Test("height clamps at, below, and above the resizable bounds")
    func heightClampsIntoBounds() {
        #expect(PanelGeometry.minimumHeight == 420)
        #expect(PanelGeometry.maximumHeight == 1_000)
        #expect(PanelGeometry.clampedHeight(420) == 420)
        #expect(PanelGeometry.clampedHeight(1_000) == 1_000)
        #expect(PanelGeometry.clampedHeight(100) == 420)
        #expect(PanelGeometry.clampedHeight(2_000) == 1_000)
        #expect(PanelGeometry.clampedHeight(560) == PanelGeometry.height)
    }

    @Test("persisted panel size falls back to the default size when keys are absent")
    func persistedSizeFallsBackToDefaultSize() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let size = PanelGeometry.persistedSize(from: defaults)

        #expect(size.contentWidth == PanelGeometry.contentWidth)
        #expect(size.height == PanelGeometry.height)
    }

    @Test("persistSize stores clamped values that persistedSize reads back")
    func persistSizeRoundTripsClamped() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PanelGeometry.persistSize(contentWidth: 500, height: 700, to: defaults)
        var size = PanelGeometry.persistedSize(from: defaults)
        #expect(size.contentWidth == 500)
        #expect(size.height == 700)

        PanelGeometry.persistSize(contentWidth: 10_000, height: 10, to: defaults)
        size = PanelGeometry.persistedSize(from: defaults)
        #expect(size.contentWidth == 720)
        #expect(size.height == 420)
    }

    @Test("out-of-bounds or invalid persisted values clamp or default on load")
    func persistedSizeClampsOutOfBoundsValues() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(10_000.0, forKey: PanelGeometry.panelContentWidthDefaultsKey)
        defaults.set(10.0, forKey: PanelGeometry.panelHeightDefaultsKey)
        var size = PanelGeometry.persistedSize(from: defaults)
        #expect(size.contentWidth == 720)
        #expect(size.height == 420)

        defaults.set("wide", forKey: PanelGeometry.panelContentWidthDefaultsKey)
        size = PanelGeometry.persistedSize(from: defaults)
        #expect(size.contentWidth == PanelGeometry.contentWidth)
        #expect(size.height == 420)
    }

    @Test("density mappings pin the compact and comfortable row metrics")
    func densityMappingsStayPinned() {
        #expect(PanelTheme.thumbnailSize(for: .compact) == 28)
        #expect(PanelTheme.thumbnailSize(for: .comfortable) == 36)
        #expect(PanelTheme.rowVerticalPadding(for: .compact) == 2)
        #expect(PanelTheme.rowVerticalPadding(for: .comfortable) == 4)
        #expect(PanelTheme.snippetLineLimit(for: .compact) == 1)
        #expect(PanelTheme.snippetLineLimit(for: .comfortable) == 2)
    }

    @Test("preview column width reads the default when the key is absent")
    func persistedPreviewColumnWidthFallsBackToDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The absent-key default IS the shipped 320 constant, so the
        // default panel keeps the pinned 400+1+320 geometry.
        #expect(PanelGeometry.previewWidth == 320)
        #expect(
            PanelGeometry.persistedPreviewColumnWidth(from: defaults)
                == PanelGeometry.previewWidth
        )
        #expect(PanelGeometry.totalWidth(previewOpen: true) == 721)
    }

    @Test("persistPreviewColumnWidth stores clamped values that read back")
    func persistPreviewColumnWidthRoundTripsClamped() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(PanelGeometry.minimumPreviewColumnWidth == 240)
        #expect(PanelGeometry.maximumPreviewColumnWidth == 480)

        PanelGeometry.persistPreviewColumnWidth(400, to: defaults)
        #expect(PanelGeometry.persistedPreviewColumnWidth(from: defaults) == 400)

        PanelGeometry.persistPreviewColumnWidth(10_000, to: defaults)
        #expect(PanelGeometry.persistedPreviewColumnWidth(from: defaults) == 480)

        PanelGeometry.persistPreviewColumnWidth(10, to: defaults)
        #expect(PanelGeometry.persistedPreviewColumnWidth(from: defaults) == 240)
    }

    @Test("out-of-bounds or invalid persisted preview widths clamp or default on load")
    func persistedPreviewColumnWidthClampsOutOfBoundsValues() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            10_000.0,
            forKey: PanelGeometry.previewColumnWidthDefaultsKey
        )
        #expect(PanelGeometry.persistedPreviewColumnWidth(from: defaults) == 480)

        defaults.set(10.0, forKey: PanelGeometry.previewColumnWidthDefaultsKey)
        #expect(PanelGeometry.persistedPreviewColumnWidth(from: defaults) == 240)

        defaults.set(
            "wide",
            forKey: PanelGeometry.previewColumnWidthDefaultsKey
        )
        #expect(
            PanelGeometry.persistedPreviewColumnWidth(from: defaults)
                == PanelGeometry.previewWidth
        )
    }

    /// One fresh, empty UserDefaults suite per test — the same isolation
    /// pattern as the ClipyApp hosted integration tests.
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "PanelAppearanceSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
