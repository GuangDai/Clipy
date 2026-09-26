import Foundation
import HistoryCore
import Testing
@testable import ClipyApp

@MainActor
struct HistoryBrowsingPreferencesTests {
    @Test
    func emptyPreferencesOpenAtLatestAndRememberWorkspaceLayout() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = HistoryBrowsingPreferences(defaults: defaults)

        #expect(preferences.panelOpeningPosition == .latest)
        #expect(preferences.workspaceOpeningPosition == .latest)
        #expect(preferences.readingItemID(for: .panel) == nil)
        #expect(preferences.readingItemID(for: .workspace) == nil)
        #expect(preferences.remembersWorkspaceLayout)
        #expect(preferences.workspaceLayout == HistoryWorkspaceLayout())
    }

    @Test
    func positionsSaveOnlyAfterEachSurfaceOptsInAndRemainIndependent() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistoryBrowsingPreferences(defaults: defaults)
        let panelItem = HistoryItemID(rawValue: UUID())
        let workspaceItem = HistoryItemID(rawValue: UUID())

        preferences.rememberReadingPosition(panelItem, for: .panel)
        preferences.rememberReadingPosition(workspaceItem, for: .workspace)
        #expect(preferences.readingItemID(for: .panel) == nil)
        #expect(preferences.readingItemID(for: .workspace) == nil)
        #expect(defaults.object(forKey: HistoryBrowsingPreferences.panelReadingItemIDKey) == nil)
        #expect(defaults.object(forKey: HistoryBrowsingPreferences.workspaceReadingItemIDKey) == nil)

        preferences.panelOpeningPosition = .lastRead
        preferences.rememberReadingPosition(panelItem, for: .panel)
        preferences.rememberReadingPosition(workspaceItem, for: .workspace)
        #expect(preferences.readingItemID(for: .panel) == panelItem)
        #expect(preferences.readingItemID(for: .workspace) == nil)
        #expect(defaults.string(forKey: HistoryBrowsingPreferences.panelReadingItemIDKey)
            == panelItem.description)
        #expect(defaults.object(forKey: HistoryBrowsingPreferences.workspaceReadingItemIDKey) == nil)

        preferences.workspaceOpeningPosition = .lastRead
        preferences.rememberReadingPosition(workspaceItem, for: .workspace)
        let reopened = HistoryBrowsingPreferences(defaults: defaults)
        #expect(reopened.panelOpeningPosition == .lastRead)
        #expect(reopened.workspaceOpeningPosition == .lastRead)
        #expect(reopened.readingItemID(for: .panel) == panelItem)
        #expect(reopened.readingItemID(for: .workspace) == workspaceItem)
        #expect(defaults.string(forKey: HistoryBrowsingPreferences.workspaceReadingItemIDKey)
            == workspaceItem.description)
    }

    @Test(arguments: [false, true])
    func selectingLatestImmediatelyDeletesOnlyThatSurfacesPosition(panel: Bool) throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistoryBrowsingPreferences(defaults: defaults)
        let panelItem = HistoryItemID(rawValue: UUID())
        let workspaceItem = HistoryItemID(rawValue: UUID())
        preferences.panelOpeningPosition = .lastRead
        preferences.workspaceOpeningPosition = .lastRead
        preferences.rememberReadingPosition(panelItem, for: .panel)
        preferences.rememberReadingPosition(workspaceItem, for: .workspace)

        if panel {
            preferences.panelOpeningPosition = .latest
        } else {
            preferences.workspaceOpeningPosition = .latest
        }

        let clearedSurface: HistoryBrowsingSurface = panel ? .panel : .workspace
        let retainedSurface: HistoryBrowsingSurface = panel ? .workspace : .panel
        let clearedKey = panel ? HistoryBrowsingPreferences.panelReadingItemIDKey
            : HistoryBrowsingPreferences.workspaceReadingItemIDKey
        let retainedKey = panel ? HistoryBrowsingPreferences.workspaceReadingItemIDKey
            : HistoryBrowsingPreferences.panelReadingItemIDKey
        let retainedItem = panel ? workspaceItem : panelItem
        #expect(preferences.readingItemID(for: clearedSurface) == nil)
        #expect(preferences.readingItemID(for: retainedSurface) == retainedItem)
        #expect(defaults.object(forKey: clearedKey) == nil)
        #expect(defaults.string(forKey: retainedKey) == retainedItem.description)

        let reopened = HistoryBrowsingPreferences(defaults: defaults)
        #expect(reopened.readingItemID(for: clearedSurface) == nil)
        #expect(reopened.readingItemID(for: retainedSurface) == retainedItem)
        #expect(reopened.panelOpeningPosition == (panel ? .latest : .lastRead))
        #expect(reopened.workspaceOpeningPosition == (panel ? .lastRead : .latest))
    }

    @Test
    func closingWithoutLoadedSelectionPreservesBothSavedPositions() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistoryBrowsingPreferences(defaults: defaults)
        let panelItem = HistoryItemID(rawValue: UUID())
        let workspaceItem = HistoryItemID(rawValue: UUID())
        preferences.panelOpeningPosition = .lastRead
        preferences.workspaceOpeningPosition = .lastRead
        preferences.rememberReadingPosition(panelItem, for: .panel)
        preferences.rememberReadingPosition(workspaceItem, for: .workspace)

        preferences.rememberReadingPosition(nil, for: .panel)
        preferences.rememberReadingPosition(nil, for: .workspace)

        #expect(preferences.readingItemID(for: .panel) == panelItem)
        #expect(preferences.readingItemID(for: .workspace) == workspaceItem)
        let reopened = HistoryBrowsingPreferences(defaults: defaults)
        #expect(reopened.readingItemID(for: .panel) == panelItem)
        #expect(reopened.readingItemID(for: .workspace) == workspaceItem)
    }

    @Test(arguments: HistorySortOrder.allCases)
    func layoutWidthSortAndDensityRoundTrip(sortOrder: HistorySortOrder) throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistoryBrowsingPreferences(defaults: defaults)
        for width in [HistoryWorkspaceLayout.minimumListWidth, 527.5] {
            for compact in [false, true] {
                let layout = HistoryWorkspaceLayout(
                    listWidth: width, sortOrder: sortOrder, compactRows: compact
                )
                preferences.workspaceLayout = layout
                let reopened = HistoryBrowsingPreferences(defaults: defaults)
                #expect(reopened.workspaceLayout == layout)
            }
        }
    }

    @Test
    func disablingLayoutMemoryKeepsCurrentLayoutAndMakesNextOpeningUseDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistoryBrowsingPreferences(defaults: defaults)
        let custom = HistoryWorkspaceLayout(
            listWidth: 580.5, sortOrder: .oldestFirst, compactRows: true
        )
        preferences.workspaceLayout = custom
        try #require(defaults.dictionary(forKey: HistoryBrowsingPreferences.workspaceLayoutKey) != nil)

        preferences.remembersWorkspaceLayout = false

        #expect(preferences.workspaceLayout == custom)
        #expect(defaults.object(forKey: HistoryBrowsingPreferences.workspaceLayoutKey) == nil)
        preferences.workspaceLayout.listWidth = 620
        #expect(preferences.workspaceLayout.listWidth == 620)
        #expect(defaults.object(forKey: HistoryBrowsingPreferences.workspaceLayoutKey) == nil)
        let reopened = HistoryBrowsingPreferences(defaults: defaults)
        #expect(!reopened.remembersWorkspaceLayout)
        #expect(reopened.workspaceLayout == HistoryWorkspaceLayout())

        preferences.remembersWorkspaceLayout = true
        let rememberedAgain = HistoryBrowsingPreferences(defaults: defaults)
        #expect(rememberedAgain.remembersWorkspaceLayout)
        #expect(rememberedAgain.workspaceLayout == preferences.workspaceLayout)
        #expect(rememberedAgain.workspaceLayout.listWidth == 620)
    }

    @Test
    func invalidLayoutFieldsRecoverWithoutDiscardingValidNeighbors() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let invalidWidths: [Any] = [true, "520", -1, 259.5, Double.infinity, Double.nan]
        for invalidWidth in invalidWidths {
            defaults.set([
                "listWidth": invalidWidth,
                "sortOrder": HistorySortOrder.mostCopied.rawValue,
                "compactRows": true,
            ], forKey: HistoryBrowsingPreferences.workspaceLayoutKey)
            let loaded = HistoryBrowsingPreferences(defaults: defaults).workspaceLayout
            #expect(loaded.listWidth == HistoryWorkspaceLayout().listWidth)
            #expect(loaded.sortOrder == .mostCopied)
            #expect(loaded.compactRows)
        }
        let invalidSorts: [Any] = ["unsupported", 123, false]
        for invalidSort in invalidSorts {
            defaults.set([
                "listWidth": 520.5,
                "sortOrder": invalidSort,
                "compactRows": true,
            ], forKey: HistoryBrowsingPreferences.workspaceLayoutKey)
            let loaded = HistoryBrowsingPreferences(defaults: defaults).workspaceLayout
            #expect(loaded.listWidth == 520.5)
            #expect(loaded.sortOrder == .automatic)
            #expect(loaded.compactRows)
        }
        let invalidBooleans: [Any] = ["true", 1, 0]
        for invalidBoolean in invalidBooleans {
            defaults.set([
                "listWidth": 520.5,
                "sortOrder": HistorySortOrder.oldestFirst.rawValue,
                "compactRows": invalidBoolean,
            ], forKey: HistoryBrowsingPreferences.workspaceLayoutKey)
            let loaded = HistoryBrowsingPreferences(defaults: defaults).workspaceLayout
            #expect(loaded.listWidth == 520.5)
            #expect(loaded.sortOrder == .oldestFirst)
            #expect(!loaded.compactRows)
        }
    }

    @Test(arguments: [false, true])
    func invalidOpeningAndItemValuesRetireOnlyTheirOwnSavedPosition(panel: Bool) throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let damagedSurface: HistoryBrowsingSurface = panel ? .panel : .workspace
        let retainedSurface: HistoryBrowsingSurface = panel ? .workspace : .panel
        let damagedOpeningKey = panel ? HistoryBrowsingPreferences.panelOpeningPositionKey
            : HistoryBrowsingPreferences.workspaceOpeningPositionKey
        let retainedOpeningKey = panel ? HistoryBrowsingPreferences.workspaceOpeningPositionKey
            : HistoryBrowsingPreferences.panelOpeningPositionKey
        let damagedItemKey = panel ? HistoryBrowsingPreferences.panelReadingItemIDKey
            : HistoryBrowsingPreferences.workspaceReadingItemIDKey
        let retainedItemKey = panel ? HistoryBrowsingPreferences.workspaceReadingItemIDKey
            : HistoryBrowsingPreferences.panelReadingItemIDKey
        let retainedItem = HistoryItemID(rawValue: UUID())
        defaults.set("unknown-opening", forKey: damagedOpeningKey)
        defaults.set(UUID().uuidString, forKey: damagedItemKey)
        defaults.set(HistoryOpeningPosition.lastRead.rawValue, forKey: retainedOpeningKey)
        defaults.set(retainedItem.description, forKey: retainedItemKey)

        let badOpening = HistoryBrowsingPreferences(defaults: defaults)
        #expect(badOpening.panelOpeningPosition == (panel ? .latest : .lastRead))
        #expect(badOpening.workspaceOpeningPosition == (panel ? .lastRead : .latest))
        #expect(badOpening.readingItemID(for: damagedSurface) == nil)
        #expect(badOpening.readingItemID(for: retainedSurface) == retainedItem)
        #expect(defaults.object(forKey: damagedItemKey) == nil)
        #expect(defaults.string(forKey: retainedItemKey) == retainedItem.description)

        defaults.set(HistoryOpeningPosition.lastRead.rawValue, forKey: damagedOpeningKey)
        defaults.set("not-an-item-uuid", forKey: damagedItemKey)
        let badItem = HistoryBrowsingPreferences(defaults: defaults)
        #expect(badItem.panelOpeningPosition == .lastRead)
        #expect(badItem.workspaceOpeningPosition == .lastRead)
        #expect(badItem.readingItemID(for: damagedSurface) == nil)
        #expect(badItem.readingItemID(for: retainedSurface) == retainedItem)
        #expect(defaults.object(forKey: damagedItemKey) == nil)
        #expect(defaults.string(forKey: retainedItemKey) == retainedItem.description)
    }

    @Test
    func invalidRememberFlagUsesDefaultWithoutDiscardingValidLayout() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistoryBrowsingPreferences(defaults: defaults)
        let custom = HistoryWorkspaceLayout(
            listWidth: 490, sortOrder: .newestFirst, compactRows: true
        )
        preferences.workspaceLayout = custom
        let invalidFlags: [Any] = ["false", 0, 1]
        for flag in invalidFlags {
            defaults.set(flag, forKey: HistoryBrowsingPreferences.remembersWorkspaceLayoutKey)
            let reopened = HistoryBrowsingPreferences(defaults: defaults)
            #expect(reopened.remembersWorkspaceLayout)
            #expect(reopened.workspaceLayout == custom)
        }
    }

    @Test(arguments: [false, true])
    func restoreDefaultsClearsPositionsAndRestoresOpeningAndLayoutOptions(
        wasRememberingLayout: Bool
    ) throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = HistoryBrowsingPreferences(defaults: defaults)
        preferences.panelOpeningPosition = .lastRead
        preferences.workspaceOpeningPosition = .lastRead
        preferences.rememberReadingPosition(HistoryItemID(rawValue: UUID()), for: .panel)
        preferences.rememberReadingPosition(HistoryItemID(rawValue: UUID()), for: .workspace)
        preferences.workspaceLayout = HistoryWorkspaceLayout(
            listWidth: 700, sortOrder: .mostCopied, compactRows: true
        )
        preferences.remembersWorkspaceLayout = wasRememberingLayout

        preferences.restoreDefaults()

        #expect(preferences.panelOpeningPosition == .latest)
        #expect(preferences.workspaceOpeningPosition == .latest)
        #expect(preferences.readingItemID(for: .panel) == nil)
        #expect(preferences.readingItemID(for: .workspace) == nil)
        #expect(defaults.object(forKey: HistoryBrowsingPreferences.panelReadingItemIDKey) == nil)
        #expect(defaults.object(forKey: HistoryBrowsingPreferences.workspaceReadingItemIDKey) == nil)
        #expect(preferences.remembersWorkspaceLayout)
        #expect(preferences.workspaceLayout == HistoryWorkspaceLayout())
        let reopened = HistoryBrowsingPreferences(defaults: defaults)
        #expect(reopened.panelOpeningPosition == .latest)
        #expect(reopened.workspaceOpeningPosition == .latest)
        #expect(reopened.remembersWorkspaceLayout)
        #expect(reopened.workspaceLayout == HistoryWorkspaceLayout())
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "HistoryBrowsingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
