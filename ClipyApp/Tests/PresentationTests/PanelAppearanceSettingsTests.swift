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

    @Test("store→load round-trips density, toggles, and custom typography")
    func storeLoadRoundTripsCustomTypography() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let customLines = try #require(HistorySnippetLineCount(rawValue: "5"))
        let customFont = try #require(HistoryRowFontSize(rawValue: "17.5"))
        for density in HistoryRowDensity.allCases {
            for autoOpen in [true, false] {
                for lineCount in [HistorySnippetLineCount.automatic, .one, .two, .three, customLines] {
                    for fontSize in [HistoryRowFontSize.small, .medium, .large, customFont] {
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
            "0",
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

    @Test("custom typography rejects invalid values and recognizes existing choices")
    func invalidCustomTypography() {
        for value in ["0", "-1", "nan", "inf", "201", "invalid"] {
            #expect(HistoryRowFontSize(rawValue: value) == nil)
        }
        for value in ["0", "-1", "1.5", "101", "invalid"] {
            #expect(HistorySnippetLineCount(rawValue: value) == nil)
        }
        #expect(HistoryRowFontSize(rawValue: "small")?.points == 11)
        #expect(HistoryRowFontSize(rawValue: "medium")?.points == 13)
        #expect(HistoryRowFontSize(rawValue: "large")?.points == 15)
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

    @Test("custom preview width is optional and survives switching back to the default")
    func customPreviewWidthPreservesPreviousChoice() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == 340)

        PanelGeometry.persistFloatingPreviewWidth(528.5, to: defaults)
        #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == 528.5)
        #expect(defaults.bool(forKey: PanelGeometry.usesCustomFloatingPreviewWidthDefaultsKey))

        defaults.set(false, forKey: PanelGeometry.usesCustomFloatingPreviewWidthDefaultsKey)
        #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == 340)
        #expect(defaults.double(forKey: PanelGeometry.floatingPreviewWidthDefaultsKey) == 528.5)
        defaults.set(true, forKey: PanelGeometry.usesCustomFloatingPreviewWidthDefaultsKey)
        #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == 528.5)

        PanelGeometry.persistFloatingPreviewWidth(10_000, to: defaults)
        #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == 10_000)
    }

    @Test("invalid preview widths cannot replace a usable saved choice or enable custom width")
    func invalidPreviewWidthPreservesPreference() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        PanelGeometry.persistFloatingPreviewWidth(480, to: defaults)
        defaults.set(false, forKey: PanelGeometry.usesCustomFloatingPreviewWidthDefaultsKey)
        for invalid in [CGFloat(0), -1, 10, .infinity, .nan] {
            PanelGeometry.persistFloatingPreviewWidth(invalid, to: defaults)
            #expect(defaults.double(forKey: PanelGeometry.floatingPreviewWidthDefaultsKey) == 480)
            #expect(!defaults.bool(forKey: PanelGeometry.usesCustomFloatingPreviewWidthDefaultsKey))
        }
        defaults.set(true, forKey: PanelGeometry.usesCustomFloatingPreviewWidthDefaultsKey)
        #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == 480)
    }

    @Test("damaged custom preview preferences recover independently of the browsing panel")
    func damagedPreviewWidthUsesDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        PanelGeometry.persistSize(contentWidth: 600, height: 720, to: defaults)
        defaults.set(true, forKey: PanelGeometry.usesCustomFloatingPreviewWidthDefaultsKey)
        for invalid in ["wide", "0", "nan"] {
            defaults.set(invalid, forKey: PanelGeometry.floatingPreviewWidthDefaultsKey)
            #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == 340)
        }
        defaults.set(10.0, forKey: PanelGeometry.floatingPreviewWidthDefaultsKey)
        #expect(PanelGeometry.persistedFloatingPreviewWidth(from: defaults) == 340)
        #expect(PanelGeometry.persistedSize(from: defaults).contentWidth == 600)
        #expect(PanelGeometry.persistedSize(from: defaults).height == 720)
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

    @Test("persistSize preserves the previous usable ceiling after a collapsed resize")
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
        #expect(size.height == 700)
    }

    @Test("out-of-bounds or invalid persisted values clamp or default on load")
    func persistedSizeClampsOutOfBoundsValues() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(10_000.0, forKey: PanelGeometry.panelContentWidthDefaultsKey)
        defaults.set(10.0, forKey: PanelGeometry.panelHeightDefaultsKey)
        var size = PanelGeometry.persistedSize(from: defaults)
        #expect(size.contentWidth == 10_000)
        #expect(size.height == PanelGeometry.height)

        defaults.set("wide", forKey: PanelGeometry.panelContentWidthDefaultsKey)
        size = PanelGeometry.persistedSize(from: defaults)
        #expect(size.contentWidth == PanelGeometry.contentWidth)
        #expect(size.height == PanelGeometry.height)
    }

    @Test("collapsed stored dimensions recover without imposing a content-fit floor",
          arguments: [0.0, 0.001, 1.0, 10.0, -1.0])
    func collapsedStoredDimensionsRecover(value: Double) throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(value, forKey: PanelGeometry.panelContentWidthDefaultsKey)
        defaults.set(value, forKey: PanelGeometry.panelHeightDefaultsKey)

        let size = PanelGeometry.persistedSize(from: defaults)
        #expect(size.contentWidth == PanelGeometry.contentWidth)
        #expect(size.height == PanelGeometry.height)
        #expect(PanelContentFit.clampedHeight(1, ceiling: size.height) == 1)
        #expect(PanelContentFit.clampedHeight(200, ceiling: size.height) == 200)
    }

    @Test("a collapsed width preserves its preference while a valid height saves")
    func collapsedWidthDoesNotDiscardValidHeight() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        PanelGeometry.persistSize(contentWidth: 500, height: 700, to: defaults)
        PanelGeometry.persistSize(contentWidth: 0.001, height: 40, to: defaults)
        let size = PanelGeometry.persistedSize(from: defaults)
        #expect(size.contentWidth == 500)
        #expect(size.height == 40)
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
