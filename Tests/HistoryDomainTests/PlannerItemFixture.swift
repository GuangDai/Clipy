import Foundation
import HistoryCore
import HistoryDomain
import Testing

/// Test input convenience. Product planners consume purpose-specific facts;
/// no product operation constructs a complete item with old revision bytes.
struct PlannerItemFixture {
    let id: HistoryItemID
    let contentVersion: ContentVersion
    let canonical: CanonicalContent
    let revisions: [ContentRevision]
    let activeRevisionID: RevisionID?
    let occurrence: CopyOccurrence
    let pinOrdinal: PinOrdinal?

    func currentContent() throws -> EffectiveContent {
        guard let activeRevisionID else {
            try #require(revisions.isEmpty)
            return EffectiveContent(representations: canonical.representations.map(\.content))
        }
        let active = revisions.filter { $0.id == activeRevisionID }
        try #require(active.count == 1)
        return try #require(active.first).content
    }
}
