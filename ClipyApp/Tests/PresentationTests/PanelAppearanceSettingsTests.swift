/// Appearance preferences round-trip through UserDefaults; user dimensions
/// preserve large-screen choices while fitting transient display constraints.
import Foundation
@testable import ClipyApp
import SwiftUI
import Testing

@Suite("Panel presentation vocabulary")
struct PanelAppearanceSettingsTests {
    @Test("absent UserDefaults keys load the product defaults")
    func absentKeysLoadProductDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = PanelAppearanceSettings.load(from: defaults)

        #expect(settings == PanelAppearanceSettings())
        #expect(settings.rowDensity == .compact)
        #expect(settings.snippetLineCount == .automatic)
        #expect(settings.rowFontSize == .medium)
        #expect(settings.isPreviewAutoOpenEnabled)
    }

    @Test("store→load round-trips every density, toggle, and typography value")
    func storeLoadRoundTripsEveryCombination() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for density in HistoryRowDensity.allCases {
            for autoOpen in [true, false] {
                for lineCount in HistorySnippetLineCount.allCases {
                    for fontSize in HistoryRowFontSize.allCases {
                        let settings = PanelAppearanceSettings(
                            rowDensity: density,
                            snippetLineCount: lineCount,
                            rowFontSize: fontSize,
                            isPreviewAutoOpenEnabled: autoOpen
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
            "4",
            forKey: PanelAppearanceSettings.snippetLineCountDefaultsKey
        )
        defaults.set(
            "huge",
            forKey: PanelAppearanceSettings.rowFontSizeDefaultsKey
        )
        defaults.set(
            "yes",
            forKey: PanelAppearanceSettings.previewAutoOpenDefaultsKey
        )

        #expect(
            PanelAppearanceSettings.load(from: defaults)
                == PanelAppearanceSettings()
        )
    }

    @Test("content width clamps at, below, and above the resizable bounds")
    func contentWidthClampsIntoBounds() {
        #expect(PanelGeometry.minimumContentWidth == 0)
        #expect(PanelGeometry.clampedContentWidth(360) == 360)
        #expect(PanelGeometry.clampedContentWidth(720) == 720)
        #expect(PanelGeometry.clampedContentWidth(100) == 100)
        #expect(PanelGeometry.clampedContentWidth(10_000) == 10_000)
        #expect(PanelGeometry.clampedContentWidth(360) == PanelGeometry.contentWidth)
    }

    @Test("height clamps at, below, and above the resizable bounds")
    func heightClampsIntoBounds() {
        // A short user size is meaningful; there is no aesthetic floor.
        #expect(PanelGeometry.minimumHeight == PanelContentFit.minimumHeight)
        #expect(PanelGeometry.clampedHeight(420) == 420)
        #expect(PanelGeometry.clampedHeight(1_000) == 1_000)
        #expect(PanelGeometry.clampedHeight(10) == 10)
        #expect(PanelGeometry.clampedHeight(2_000) == 2_000)
        #expect(PanelGeometry.clampedHeight(420) == PanelGeometry.height)
    }

    @Test func finitePreferencesClampToDefaults() {
        #expect(PanelGeometry.clampedContentWidth(.infinity) == PanelGeometry.contentWidth)
        #expect(PanelGeometry.clampedHeight(.nan) == PanelGeometry.height)
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
        #expect(size.contentWidth == 10_000)
        #expect(size.height == 10)
    }

    @Test("out-of-bounds or invalid persisted values clamp or default on load")
    func persistedSizeClampsOutOfBoundsValues() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(10_000.0, forKey: PanelGeometry.panelContentWidthDefaultsKey)
        defaults.set(10.0, forKey: PanelGeometry.panelHeightDefaultsKey)
        var size = PanelGeometry.persistedSize(from: defaults)
        #expect(size.contentWidth == 10_000)
        #expect(size.height == 10)

        defaults.set("wide", forKey: PanelGeometry.panelContentWidthDefaultsKey)
        size = PanelGeometry.persistedSize(from: defaults)
        #expect(size.contentWidth == PanelGeometry.contentWidth)
        #expect(size.height == 10)
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
