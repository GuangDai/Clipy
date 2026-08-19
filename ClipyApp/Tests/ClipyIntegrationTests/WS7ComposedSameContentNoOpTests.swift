/// WS7Composed — Same-content revision no-op through the composed app stack
/// (docs/06-cross-cutting.md §8 WS7; docs/02-domain.md §11): a replace — or
/// a revert — whose proposed Effective Content equals the current bytes
/// returns `.unchanged`: no appended revision, no Content Version or Change
/// Position advance, and nothing new emitted to observation.
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct WS7ComposedSameContentNoOpTests {

    /// WS7 (docs/06-cross-cutting.md §8): both no-op revision shapes — a
    /// `.replace` with the current bytes and a `.revert(to: .canonical)`
    /// while Effective already IS Canonical — return `.unchanged`, append no
    /// revision, and advance neither token. The position proof: the next
    /// real commit lands at Change Position 2 after exactly one insert.
    @Test
    func replaceWithIdenticalBytesAndCanonicalEchoAreNoOps() async throws {
        let history = try await ComposedSupport.openMemoryHistory()

        let text = "ws7 composed stable text"
        let observedAt = Date(timeIntervalSinceReferenceDate: 700_201_100)

        let insertReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                text,
                observedAt: observedAt,
                source: "com.example.ws7composed"
            )
        ))
        let inserted = try #require(
            ComposedSupport.insertedReference(from: insertReceipt, "WS7 arrange")
        )

        // (a) Replace proposing the CURRENT Effective bytes.
        let identicalReplace = try await history.perform(.revise(
            RevisionRequest(
                itemID: inserted.id,
                expected: inserted.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(
                        typeIdentifier: ComposedSupport.plainTextTypeIdentifier,
                        action: .replace(bytes: Data(text.utf8))
                    ),
                ]))
            )
        ))
        guard case .unchanged = identicalReplace else {
            Issue.record(
                "WS7 (a): expected .unchanged for identical replace, got \(identicalReplace)"
            )
            return
        }

        // (b) Revert to Canonical while Effective already equals Canonical.
        let canonicalEchoRevert = try await history.perform(.revise(
            RevisionRequest(
                itemID: inserted.id,
                expected: inserted.contentVersion,
                intent: .revert(to: .canonical)
            )
        ))
        guard case .unchanged = canonicalEchoRevert else {
            Issue.record(
                "WS7 (b): expected .unchanged for the canonical echo, got \(canonicalEchoRevert)"
            )
            return
        }

        // No revision was appended and no Content Version was minted.
        let details = try await history.details(for: inserted.id)
        #expect(details.revisions.isEmpty, "WS7: no revision appended")
        #expect(details.item.contentVersion.rawValue == 1)

        // No Change Position advance: the next commit is Change Position 2
        // (one insert so far) — both no-ops advanced nothing (02 §13).
        let secondReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws7 composed second item",
                observedAt: observedAt.addingTimeInterval(100),
                source: "com.example.ws7composed"
            )
        ))
        let secondCommit = try #require(
            ComposedSupport.commit(of: secondReceipt, "WS7")
        )
        #expect(
            secondCommit.position.rawValue == 2,
            "WS7: neither no-op advanced Change Position"
        )
    }
}
