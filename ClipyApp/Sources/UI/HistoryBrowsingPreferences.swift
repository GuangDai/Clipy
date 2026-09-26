import CoreFoundation
import Foundation
import HistoryCore
import Observation
import SwiftUI

enum HistoryOpeningPosition: String, CaseIterable, Sendable {
    case latest
    case lastRead
}

enum HistoryBrowsingSurface: Equatable, Sendable {
    case panel
    case workspace
}

struct HistoryWorkspaceLayout: Equatable, Sendable {
    var listWidth: Double = 350
    var sortOrder: HistorySortOrder = .automatic
    var compactRows = false

    /// A smaller window fits this preference temporarily; it never replaces
    /// the saved width just because the available display has changed.
    static let minimumListWidth: Double = 260
}

/// UI preferences store only dimensions, presentation choices and at most
/// one item UUID per surface. Query text, content and page cursors are absent.
@MainActor @Observable
final class HistoryBrowsingPreferences {
    static let panelOpeningPositionKey = "clipy.browsing.panelOpeningPosition"
    static let workspaceOpeningPositionKey = "clipy.browsing.workspaceOpeningPosition"
    static let panelReadingItemIDKey = "clipy.browsing.panelReadingItemID"
    static let workspaceReadingItemIDKey = "clipy.browsing.workspaceReadingItemID"
    static let remembersWorkspaceLayoutKey = "clipy.browsing.remembersWorkspaceLayout"
    static let workspaceLayoutKey = "clipy.browsing.workspaceLayout"

    private let defaults: UserDefaults
    private var panelReadingItemID: HistoryItemID?
    private var workspaceReadingItemID: HistoryItemID?

    var panelOpeningPosition: HistoryOpeningPosition {
        didSet {
            defaults.set(panelOpeningPosition.rawValue, forKey: Self.panelOpeningPositionKey)
            if panelOpeningPosition == .latest { clearReadingPosition(for: .panel) }
        }
    }

    var workspaceOpeningPosition: HistoryOpeningPosition {
        didSet {
            defaults.set(workspaceOpeningPosition.rawValue, forKey: Self.workspaceOpeningPositionKey)
            if workspaceOpeningPosition == .latest { clearReadingPosition(for: .workspace) }
        }
    }

    var remembersWorkspaceLayout: Bool {
        didSet {
            defaults.set(remembersWorkspaceLayout, forKey: Self.remembersWorkspaceLayoutKey)
            if remembersWorkspaceLayout {
                storeWorkspaceLayout()
            } else {
                // Opting out does not move the currently visible divider.
                defaults.removeObject(forKey: Self.workspaceLayoutKey)
            }
        }
    }

    var workspaceLayout: HistoryWorkspaceLayout {
        didSet {
            if !workspaceLayout.listWidth.isFinite
                || workspaceLayout.listWidth < HistoryWorkspaceLayout.minimumListWidth {
                workspaceLayout.listWidth = HistoryWorkspaceLayout().listWidth
            }
            if remembersWorkspaceLayout { storeWorkspaceLayout() }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let panelPosition = defaults.string(forKey: Self.panelOpeningPositionKey)
            .flatMap(HistoryOpeningPosition.init(rawValue:)) ?? .latest
        let workspacePosition = defaults.string(forKey: Self.workspaceOpeningPositionKey)
            .flatMap(HistoryOpeningPosition.init(rawValue:)) ?? .latest
        let remembersLayout = Self.boolean(
            defaults.object(forKey: Self.remembersWorkspaceLayoutKey), fallback: true
        )
        panelOpeningPosition = panelPosition
        workspaceOpeningPosition = workspacePosition
        remembersWorkspaceLayout = remembersLayout
        workspaceLayout = remembersLayout ? Self.loadWorkspaceLayout(from: defaults) : .init()
        panelReadingItemID = panelPosition == .lastRead
            ? defaults.string(forKey: Self.panelReadingItemIDKey).flatMap(HistoryItemID.init(uuidString:)) : nil
        workspaceReadingItemID = workspacePosition == .lastRead
            ? defaults.string(forKey: Self.workspaceReadingItemIDKey).flatMap(HistoryItemID.init(uuidString:)) : nil
        if panelReadingItemID == nil { defaults.removeObject(forKey: Self.panelReadingItemIDKey) }
        if workspaceReadingItemID == nil { defaults.removeObject(forKey: Self.workspaceReadingItemIDKey) }
        if !remembersWorkspaceLayout { defaults.removeObject(forKey: Self.workspaceLayoutKey) }
    }

    func readingItemID(for surface: HistoryBrowsingSurface) -> HistoryItemID? {
        switch surface {
        case .panel: panelOpeningPosition == .lastRead ? panelReadingItemID : nil
        case .workspace: workspaceOpeningPosition == .lastRead ? workspaceReadingItemID : nil
        }
    }

    /// A close while loading has no new reading position. Keep the previous
    /// UUID in that case; choosing Latest explicitly removes it immediately.
    func rememberReadingPosition(_ itemID: HistoryItemID?, for surface: HistoryBrowsingSurface) {
        let position = surface == .panel ? panelOpeningPosition : workspaceOpeningPosition
        guard position == .lastRead else { clearReadingPosition(for: surface); return }
        guard let itemID else { return }
        switch surface {
        case .panel:
            panelReadingItemID = itemID
            defaults.set(itemID.description, forKey: Self.panelReadingItemIDKey)
        case .workspace:
            workspaceReadingItemID = itemID
            defaults.set(itemID.description, forKey: Self.workspaceReadingItemIDKey)
        }
    }

    func clearReadingPosition(for surface: HistoryBrowsingSurface) {
        switch surface {
        case .panel:
            panelReadingItemID = nil
            defaults.removeObject(forKey: Self.panelReadingItemIDKey)
        case .workspace:
            workspaceReadingItemID = nil
            defaults.removeObject(forKey: Self.workspaceReadingItemIDKey)
        }
    }

    func resetWorkspaceLayout() {
        workspaceLayout = .init()
    }

    func restoreDefaults() {
        panelOpeningPosition = .latest
        workspaceOpeningPosition = .latest
        clearReadingPosition(for: .workspace)
        workspaceLayout = .init()
        remembersWorkspaceLayout = true
    }

    private func storeWorkspaceLayout() {
        let values: [String: Any] = [
            "listWidth": workspaceLayout.listWidth,
            "sortOrder": workspaceLayout.sortOrder.rawValue,
            "compactRows": workspaceLayout.compactRows,
        ]
        defaults.set(values, forKey: Self.workspaceLayoutKey)
    }

    private static func loadWorkspaceLayout(from defaults: UserDefaults) -> HistoryWorkspaceLayout {
        guard let values = defaults.dictionary(forKey: workspaceLayoutKey) else { return .init() }
        var layout = HistoryWorkspaceLayout()
        if let width = values["listWidth"] as? NSNumber,
           CFGetTypeID(width) != CFBooleanGetTypeID(),
           width.doubleValue.isFinite, width.doubleValue >= HistoryWorkspaceLayout.minimumListWidth {
            layout.listWidth = width.doubleValue
        }
        if let rawSort = values["sortOrder"] as? String,
           let sort = HistorySortOrder(rawValue: rawSort) {
            layout.sortOrder = sort
        }
        layout.compactRows = boolean(values["compactRows"], fallback: false)
        return layout
    }

    private static func boolean(_ raw: Any?, fallback: Bool) -> Bool {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return fallback }
        return number.boolValue
    }
}

extension EnvironmentValues {
    @Entry var historyBrowsingPreferences: HistoryBrowsingPreferences? = nil
}

enum HistoryBrowsingCopy {
    static func text(_ english: String, bundle: Bundle = AppLocalization.bundle) -> String {
        bundle.localizedString(forKey: english, value: english, table: "HistoryBrowsing")
    }
}
