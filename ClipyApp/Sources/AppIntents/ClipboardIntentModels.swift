/// Content-bounded App Intents projections. These transient entities are
/// outputs only: resolving durable identity always goes through the explicit
/// string parameter and the capability-gated facade (V2-05 §6.6; X.7).
import AppIntents
import Foundation
import HistoryCore

enum ClipboardSearchMode: String, AppEnum, Sendable {
    case exact
    case fuzzy
    case regexp

    static let typeDisplayRepresentation: TypeDisplayRepresentation =
        "Search Mode"

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .exact: "Exact",
        .fuzzy: "Fuzzy",
        .regexp: "Regular Expression",
    ]

    var historyMode: SearchMode {
        switch self {
        case .exact: .exact
        case .fuzzy: .fuzzy
        case .regexp: .regexp
        }
    }
}

struct ClipboardHistoryItemEntity: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation =
        "Clipboard History Item"

    var id: String

    @Property(title: "Title")
    var title: String

    @Property(title: "Type Identifiers")
    var typeIdentifiers: [String]

    @Property(title: "Last Copied")
    var lastCopiedAt: Date

    @Property(title: "Copy Count")
    var copyCount: String

    @Property(title: "Source Application")
    var lastSource: String?

    @Property(title: "Pinned")
    var isPinned: Bool

    @Property(title: "Revision Count")
    var revisionCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init() {
        id = ""
        title = ""
        typeIdentifiers = []
        lastCopiedAt = .distantPast
        copyCount = "0"
        lastSource = nil
        isPinned = false
        revisionCount = 0
    }

    init(row: HistoryRow) {
        id = row.item.id.description
        title = row.title
        typeIdentifiers = row.typeIdentifiers
        lastCopiedAt = row.lastCopiedAt
        copyCount = String(row.copyCount)
        lastSource = row.lastSource
        isPinned = row.pinnedPosition != nil
        revisionCount = 0
    }

    init(details: HistoryDetails) {
        id = details.item.id.description
        title = "Clipboard Item"
        typeIdentifiers = details.effective.map(\.typeIdentifier)
        lastCopiedAt = details.occurrence.lastCopiedAt
        copyCount = String(details.occurrence.count)
        lastSource = details.occurrence.lastSource
        isPinned = details.pinnedPosition != nil
        revisionCount = details.revisions.count
    }
}
