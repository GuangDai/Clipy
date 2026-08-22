/// WS6Composed — Revision OCC and append-only revert through the composed
/// app stack (docs/06-cross-cutting.md §8 WS6; docs/02-domain.md §11;
/// docs/05-authority-kernel.md §6.2): create an item, append a
/// content-changing revision, submit a stale draft (expect `.staleContent`,
/// no commit), then revert to Canonical and observe the new Revision ID, the
/// untouched old revisions, and the Effective-derived reads updated.
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct WS6ComposedRevisionOCCAndRevertTests {

    /// A `.replace` draft substituting new bytes for the single plain-text
    /// representation, OCC-tokened at `expected` (docs/03a-instruction-set.md §5).
    private static func replaceTextRequest(
        itemID: HistoryItemID,
        expected: ContentVersion,
        text: String
    ) -> RevisionRequest {
        RevisionRequest(
            itemID: itemID,
            expected: expected,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                    action: .replace(bytes: Data(text.utf8))
                ),
            ]))
        )
    }

    /// WS6 (docs/06-cross-cutting.md §8): a stale draft returns
    /// `.staleContent` with no commit; a revert from the current version to
    /// Canonical appends a NEW revision (old revisions unchanged), updates
    /// the Effective-derived reads (details, paste payload), and advances
    /// Content Version exactly once.
    @Test
    func staleDraftRejectsAndCanonicalRevertAppendsNewRevision() async throws {
        let history = try await ComposedSupport.openMemoryHistory()

        let originalText = "ws6 composed original"
        let revisedText = "ws6 composed replacement"
        let observedAt = Date(timeIntervalSinceReferenceDate: 700_201_000)

        // Create the item.
        let insertReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                originalText,
                observedAt: observedAt,
                source: "com.example.ws6composed"
            )
        ))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS6 arrange")
        )

        // Append a changing revision: Content Version 1 → 2.
        let reviseReceipt = try await history.perform(.revise(
            Self.replaceTextRequest(
                itemID: inserted.id,
                expected: inserted.contentVersion,
                text: revisedText
            )
        ))
        let revised = try #require(
            ComposedSupport.revisedReference(from: reviseReceipt, "WS6 revise")
        )
        #expect(revised.contentVersion.rawValue == 2)
        let detailsAfterRevise = try await history.details(for: inserted.id)
        let firstRevisionID = try #require(
            detailsAfterRevise.revisions.last?.id,
            "WS6: the first revision is appended and summarized"
        )

        // Stale draft based on the superseded version 1: rejected with
        // `.staleContent(expected:current:)`, nothing committed.
        do {
            _ = try await history.perform(.revise(
                Self.replaceTextRequest(
                    itemID: inserted.id,
                    expected: inserted.contentVersion,
                    text: "ws6 composed stale proposal"
                )
            ))
            Issue.record("WS6: expected .staleContent, got a receipt")
        } catch let failure as HistoryFailure {
            guard case let .staleContent(expected, current) = failure else {
                Issue.record("WS6: expected .staleContent, got \(failure)")
                return
            }
            #expect(expected.rawValue == 1)
            #expect(current.rawValue == 2)
        }

        // No commit from the stale attempt: the durable state still shows
        // the version-2 Effective Content, and the position proof below
        // shows no phantom advance.
        let afterStale = try await history.details(for: inserted.id)
        #expect(afterStale.item.contentVersion.rawValue == 2)
        #expect(afterStale.effective.first?.bytes == Data(revisedText.utf8))

        // Revert from the current version to Canonical (docs/03a-instruction-set.md
        // §5 `.revert(to: .canonical)`): one successor Content Version, a
        // NEW Revision ID appended, old revisions unchanged.
        let revertReceipt = try await history.perform(.revise(
            RevisionRequest(
                itemID: inserted.id,
                expected: afterStale.item.contentVersion,
                intent: .revert(to: .canonical)
            )
        ))
        let commit = try #require(ComposedSupport.commit(of: revertReceipt, "WS6 revert"))
        #expect(
            commit.position.rawValue == 3,
            "WS6: insert(1) + revise(2) + revert(3) — the stale attempt advanced nothing"
        )
        let reverted = try #require(
            ComposedSupport.revisedReference(from: revertReceipt, "WS6 revert")
        )
        #expect(
            reverted.contentVersion.rawValue == 3,
            "WS6: the revert mints exactly one successor Content Version"
        )

        // Append-only lineage: BOTH revisions retained, the newest active,
        // the first revision's ID unchanged.
        let details = try await history.details(for: inserted.id)
        #expect(details.revisions.count == 2)
        #expect(details.revisions.first?.id == firstRevisionID)
        #expect(details.revisions.last?.isActive == true)
        #expect(details.revisions.first?.isActive == false)

        // Effective-derived reads updated: Effective and paste payload
        // carry the CANONICAL bytes again (docs/03b-instruction-set.md §9).
        #expect(details.effective.first?.bytes == Data(originalText.utf8))
        #expect(details.canonical.first?.bytes == Data(originalText.utf8))
        let payload = try await history.pastePayload(for: inserted.id)
        #expect(payload.representations.first?.bytes == Data(originalText.utf8))
        #expect(payload.item.contentVersion == reverted.contentVersion)
    }
}
