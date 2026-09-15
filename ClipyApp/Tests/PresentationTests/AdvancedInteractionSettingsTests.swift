import Foundation
@testable import ClipyApp
@testable import HistoryCore
@testable import HistoryStorage
import Testing

@MainActor
struct AdvancedInteractionSettingsTests {
    @Test func invalidPersistedFieldsDoNotDamageValidNeighbors() throws {
        let suite = "AdvancedInteractionSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let malformed: [String: Any] = [
            "remembersSearch": false,
            "selectsOnHover": "false",
            "previewDelayMilliseconds": Double.infinity,
            "pointerGraceMilliseconds": 650
        ]
        defaults.set(malformed, forKey: AdvancedInteractionSettings.defaultsKey)
        let loaded = AdvancedInteractionSettings.load(from: defaults)
        #expect(!loaded.remembersSearch)
        #expect(loaded.selectsOnHover)
        #expect(loaded.previewDelay == .milliseconds(200))
        #expect(loaded.pointerGrace == .milliseconds(650))

        let malformedValues: [Any] = [true, -1, 1.5, "200", Int.max]
        for malformed in malformedValues {
            defaults.set(["previewDelayMilliseconds": malformed],
                         forKey: AdvancedInteractionSettings.defaultsKey)
            #expect(AdvancedInteractionSettings.load(from: defaults).previewDelay == .milliseconds(200))
        }
    }

    @Test func independentControlsMergeIntoTheLatestPersistedValue() throws {
        let suite = "AdvancedInteractionSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AdvancedInteractionSettings.update(in: defaults) { $0.remembersSearch = false }
        AdvancedInteractionSettings.update(in: defaults) { $0.previewDelayMilliseconds = 800 }
        AdvancedInteractionSettings.update(in: defaults) { $0.selectsOnHover = false }
        let loaded = AdvancedInteractionSettings.load(from: defaults)
        #expect(!loaded.remembersSearch)
        #expect(!loaded.selectsOnHover)
        #expect(loaded.previewDelay == .milliseconds(800))
        #expect(loaded.pointerGrace == .milliseconds(150))
    }

    @Test func changingDelayRetiresOldTimerAndKeepsTheCurrentSelection() async {
        let preview = PreviewPaneState(autoOpenDelay: .seconds(3_600))
        defer { preview.panelClosed() }
        let item = HistoryItemReference(
            id: HistoryItemID(rawValue: UUID()), contentVersion: ContentVersion(rawValue: 1)
        )
        preview.handleSelectionChange(item)
        var settings = AdvancedInteractionSettings()
        settings.previewDelayMilliseconds = 0
        preview.applyInteractionSettings(settings)
        for _ in 0..<10_000 {
            if preview.isOpen { break }
            await Task.yield()
        }
        #expect(preview.previewedItem == item)
        #expect(preview.isOpen)
        preview.dismissPreview()
        settings.previewDelayMilliseconds = 50
        preview.applyInteractionSettings(settings)
        #expect(!preview.isOpen)
    }

    @Test func delayEditsRespectMemoryPressureAndClosedPanel() async {
        let preview = PreviewPaneState(autoOpenDelay: .seconds(3_600))
        let item = HistoryItemReference(
            id: HistoryItemID(rawValue: UUID()), contentVersion: ContentVersion(rawValue: 1)
        )
        preview.handleSelectionChange(item)
        preview.respondToMemoryPressure(.critical)
        var settings = AdvancedInteractionSettings()
        settings.previewDelayMilliseconds = 0
        preview.applyInteractionSettings(settings)
        #expect(!preview.isOpen)
        #expect(preview.isAutoOpenSuspendedForMemoryPressure)
        preview.respondToMemoryPressure(.normal)
        for _ in 0..<10_000 {
            if preview.isOpen { break }
            await Task.yield()
        }
        #expect(preview.previewedItem == item)
        preview.panelClosed()
        settings.previewDelayMilliseconds = 50
        preview.applyInteractionSettings(settings)
        #expect(!preview.isOpen)
    }

    @Test func changingGraceReplacesPendingHideAndDoesNotCancelPointerReentry() async {
        let preview = PreviewPaneState(pointerExitGrace: .seconds(3_600))
        defer { preview.panelClosed() }
        let item = HistoryItemReference(
            id: HistoryItemID(rawValue: UUID()), contentVersion: ContentVersion(rawValue: 1)
        )
        preview.togglePreview(for: item)
        preview.isPointerInteractionActive = true
        preview.pointerEntered(.mainPanel)
        preview.pointerExited(.mainPanel)
        var settings = AdvancedInteractionSettings()
        settings.pointerGraceMilliseconds = 0
        preview.applyInteractionSettings(settings)
        for _ in 0..<10_000 {
            if !preview.isOpen { break }
            await Task.yield()
        }
        #expect(!preview.isOpen)

        preview.togglePreview(for: item)
        preview.pointerEntered(.mainPanel)
        preview.pointerExited(.mainPanel)
        preview.pointerEntered(.preview)
        settings.pointerGraceMilliseconds = 50
        preview.applyInteractionSettings(settings)
        #expect(preview.isOpen)
    }

    @Test func disablingHoverRetiresDeferredSelectionButPreservesKeyboardNavigation() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let rows = [
            fixtureRow(id: "00000000-0000-0000-0000-000000003701", title: "first"),
            fixtureRow(id: "00000000-0000-0000-0000-000000003702", title: "second")
        ]
        let surface = HistoryPanelSurfaceState(history: history, previewState: PreviewPaneState())
        surface.beginSession(rows: rows)
        surface.moveSelection(in: rows, direction: .next)
        defer { surface.endSession() }
        surface.handleRowHover(rows[1].item.id)
        #expect(surface.deferredHoverSelection == rows[1].item.id)
        surface.selectsOnHover = false
        surface.notePointerMovement()
        surface.handleRowHover(rows[1].item.id)
        #expect(surface.deferredHoverSelection == nil)
        #expect(surface.selection == rows[0].item.id)
        surface.moveSelection(in: rows, direction: .next)
        #expect(surface.selection == rows[1].item.id)
    }
}
