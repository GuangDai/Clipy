/// The complete six-intent X.7 surface. Each perform method maps to exactly
/// one External Gateway operation; policy, grants, rate limits, and audit stay
/// behind the connection-bound facade (V2-05 §3.2/§6.6).
import AppIntents
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import PasteboardAdapter

struct SearchHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Clipboard History"
    static let description = IntentDescription(
        "Search retained clipboard items."
    )
    static let supportedModes: IntentModes = [.background]

    @Parameter(title: "Query", description: "Search text.")
    var query: String

    @Parameter(title: "Mode", default: ClipboardSearchMode.exact)
    var mode: ClipboardSearchMode

    @Parameter(
        title: "Limit",
        default: 20,
        controlStyle: .stepper,
        inclusiveRange: (lowerBound: 1, upperBound: 500)
    )
    var limit: Int

    @Dependency private var history: ExternalHistoryFacade

    init() {}

    init(
        query: String,
        mode: ClipboardSearchMode,
        limit: Int,
        history: ExternalHistoryFacade,
        dependencyManager: AppDependencyManager
    ) {
        self.query = query
        self.mode = mode
        self.limit = limit
        _history = AppDependency(
            manager: dependencyManager,
            default: history
        )
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[
        ClipboardHistoryItemEntity
    ]> {
        do {
            let result = try await history.read(.search(
                text: query,
                mode: mode.historyMode,
                limit: limit
            ))
            guard case .page(let page) = result else {
                throw ClipboardIntentFailure.temporarilyUnavailable
            }
            return .result(value: page.rows.map {
                ClipboardHistoryItemEntity(row: $0)
            })
        } catch {
            throw ClipboardIntentFailure.map(error)
        }
    }
}

struct GetItemDetailsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Clipboard Item Details"
    static let description = IntentDescription(
        "Get metadata for one retained clipboard item."
    )
    static let supportedModes: IntentModes = [.background]

    @Parameter(title: "Item ID", description: "Clipboard item identifier.")
    var itemID: String

    @Dependency private var history: ExternalHistoryFacade

    init() {}

    init(
        itemID: String,
        history: ExternalHistoryFacade,
        dependencyManager: AppDependencyManager
    ) {
        self.itemID = itemID
        _history = AppDependency(
            manager: dependencyManager,
            default: history
        )
    }

    func perform() async throws -> some IntentResult & ReturnsValue<
        ClipboardHistoryItemEntity
    > {
        do {
            let id = try parsedHistoryItemID(itemID)
            let result = try await history.read(.details(id))
            guard case .details(let details) = result else {
                throw ClipboardIntentFailure.temporarilyUnavailable
            }
            return .result(value: ClipboardHistoryItemEntity(details: details))
        } catch {
            throw ClipboardIntentFailure.map(error)
        }
    }
}

struct PasteItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Clipboard History Item"
    static let description = IntentDescription(
        "Copy one retained item to the clipboard."
    )
    static let supportedModes: IntentModes = [.background]

    @Parameter(title: "Item ID", description: "Clipboard item identifier.")
    var itemID: String

    @Dependency private var history: ExternalHistoryFacade

    /// A Sendable name is the whole deterministic test seam. AppKit objects
    /// are created and consumed only inside the MainActor write below.
    private var pasteboardName: String?

    init() {
        pasteboardName = nil
    }

    init(
        itemID: String,
        pasteboardName: String,
        history: ExternalHistoryFacade,
        dependencyManager: AppDependencyManager
    ) {
        self.itemID = itemID
        self.pasteboardName = pasteboardName
        _history = AppDependency(
            manager: dependencyManager,
            default: history
        )
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        do {
            let id = try parsedHistoryItemID(itemID)
            let result = try await history.read(.pastePayload(id))
            guard case .pastePayload(let payload) = result else {
                throw ClipboardIntentFailure.temporarilyUnavailable
            }
            let name = pasteboardName
            try await MainActor.run {
                let pasteboard = name.map {
                    NSPasteboard(name: NSPasteboard.Name($0))
                } ?? .general
                try PasteboardAdapter(pasteboard: pasteboard).write(payload)
            }
            return .result(value: true)
        } catch {
            throw ClipboardIntentFailure.map(error)
        }
    }
}

struct PinItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin Clipboard History Item"
    static let description = IntentDescription("Pin one retained item.")
    static let supportedModes: IntentModes = [.background]

    @Parameter(title: "Item ID", description: "Clipboard item identifier.")
    var itemID: String

    @Dependency private var history: ExternalHistoryFacade

    init() {}

    init(
        itemID: String,
        history: ExternalHistoryFacade,
        dependencyManager: AppDependencyManager
    ) {
        self.itemID = itemID
        _history = AppDependency(
            manager: dependencyManager,
            default: history
        )
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        do {
            let response = try await history.perform(.pin(
                try parsedHistoryItemID(itemID)
            ))
            switch response {
            case .pin:
                return .result(value: true)
            case .unchanged:
                return .result(value: false)
            case .unpin, .removed:
                throw ClipboardIntentFailure.temporarilyUnavailable
            }
        } catch {
            throw ClipboardIntentFailure.map(error)
        }
    }
}

struct UnpinItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Unpin Clipboard History Item"
    static let description = IntentDescription("Unpin one retained item.")
    static let supportedModes: IntentModes = [.background]

    @Parameter(title: "Item ID", description: "Clipboard item identifier.")
    var itemID: String

    @Dependency private var history: ExternalHistoryFacade

    init() {}

    init(
        itemID: String,
        history: ExternalHistoryFacade,
        dependencyManager: AppDependencyManager
    ) {
        self.itemID = itemID
        _history = AppDependency(
            manager: dependencyManager,
            default: history
        )
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        do {
            let response = try await history.perform(.unpin(
                try parsedHistoryItemID(itemID)
            ))
            switch response {
            case .unpin:
                return .result(value: true)
            case .unchanged:
                return .result(value: false)
            case .pin, .removed:
                throw ClipboardIntentFailure.temporarilyUnavailable
            }
        } catch {
            throw ClipboardIntentFailure.map(error)
        }
    }
}

struct RemoveItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove Clipboard History Item"
    static let description = IntentDescription(
        "Remove one retained clipboard item."
    )
    static let supportedModes: IntentModes = [.background]

    @Parameter(title: "Item ID", description: "Clipboard item identifier.")
    var itemID: String

    @Dependency private var history: ExternalHistoryFacade

    init() {}

    init(
        itemID: String,
        history: ExternalHistoryFacade,
        dependencyManager: AppDependencyManager
    ) {
        self.itemID = itemID
        _history = AppDependency(
            manager: dependencyManager,
            default: history
        )
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        do {
            let response = try await history.perform(.remove(
                try parsedHistoryItemID(itemID)
            ))
            switch response {
            case .removed(let count):
                return .result(value: count > 0)
            case .unchanged:
                return .result(value: false)
            case .pin, .unpin:
                throw ClipboardIntentFailure.temporarilyUnavailable
            }
        } catch {
            throw ClipboardIntentFailure.map(error)
        }
    }
}

private func parsedHistoryItemID(
    _ value: String
) throws -> HistoryItemID {
    guard let id = HistoryItemID(uuidString: value) else {
        throw ClipboardIntentFailure.invalidRequest
    }
    return id
}
