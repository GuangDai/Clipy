import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct RevisionCurrentInheritanceTests {
    @Test
    func currentInheritancePreservesBinaryBytesAndIsANoOp() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let type = "com.example.binary"
        let canonical = Data(repeating: 1, count: 100_000)
        let current = Data(repeating: 2, count: canonical.count)
        let capture = ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: type, bytes: canonical)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_093_000)
        )
        let inserted = try reference(from: await history.perform(.capture(capture)))
        let revised = try reference(from: await history.perform(.revise(request(
            inserted, type: type, action: .replace(bytes: current)
        ))))
        let changed = try await history.details(for: revised.id)
        // Same identifiers and lengths cannot establish byte equality.
        #expect(changed.canonical == changed.effective)
        #expect(!changed.effectiveMatchesCanonical)

        let noOp = try await history.perform(.revise(request(revised, type: type, action: .inheritCurrent)))
        guard case .unchanged = noOp else { Issue.record("Keeping current bytes must be unchanged"); return }
        #expect(try await history.details(for: revised.id) == changed)
        #expect(try await history.pastePayload(for: revised.id).representations.first?.bytes == current)
        await #expect(throws: HistoryFailure.staleContent(expected: inserted.contentVersion, current: revised.contentVersion)) {
            try await history.perform(.revise(request(inserted, type: type, action: .inheritCanonical)))
        }
        #expect(try await history.details(for: revised.id) == changed)

        _ = try await history.perform(.placePinned(revised.id, at: .first))
        #expect(try await history.details(for: revised.id).effectiveMatchesCanonical == false)
        _ = try await history.perform(.unpin(revised.id))
        _ = try await history.perform(.capture(capture))
        #expect(try await history.details(for: revised.id).effectiveMatchesCanonical == false)
        let next = try reference(from: await history.perform(.revise(request(
            revised, type: type, action: .replace(bytes: Data(repeating: 3, count: canonical.count))
        ))))
        _ = try await history.perform(.setRetentionPolicies(HistoryRetentionPolicies(
            age: nil, storage: nil,
            revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
        )))
        let pruned = try await history.details(for: next.id)
        #expect(pruned.revisions.count == 1)
        #expect(!pruned.effectiveMatchesCanonical)
        let reverted = try reference(from: await history.perform(.revise(RevisionRequest(
            itemID: next.id, expected: next.contentVersion, intent: .revert(to: .canonical)
        ))))
        let restored = try await history.details(for: reverted.id)
        #expect(restored.effectiveMatchesCanonical)
        #expect(!restored.revisions.isEmpty)
        #expect(try await history.pastePayload(for: reverted.id).representations.first?.bytes == canonical)
    }

    @Test
    func equivalentIdentifierSpellingsAndDifferentOrdersStillMatchCanonical() async throws {
        let decomposed = "e\u{301}"
        let composed = "\u{e9}"
        let canonical = try CanonicalContent(representations: [
            CanonicalRepresentation(content: ContentRepresentation(typeIdentifier: decomposed, bytes: Data([1])), fingerprint: ContentFingerprint(rawValue: 91)),
            CanonicalRepresentation(content: ContentRepresentation(typeIdentifier: "f", bytes: Data([2])), fingerprint: ContentFingerprint(rawValue: 92)),
        ])
        let current = EffectiveContent(representations: [
            ContentRepresentation(typeIdentifier: "f", bytes: Data([2])),
            ContentRepresentation(typeIdentifier: composed, bytes: Data([1])),
        ])
        let source = snapshot(canonical: canonical, current: current)
        let request = RevisionRequest(
            itemID: HistoryItemID(rawValue: UUID()), expected: source.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: decomposed, action: .inheritCurrent),
                RevisionDecision(typeIdentifier: "f", action: .inheritCurrent),
            ]))
        )
        let prepared = try await RevisionPreparationActor().prepare(request, from: source)
        #expect(prepared.domain.proposedContent.representations != canonical.representations.map(\.content))
        #expect(prepared.domain.proposedContent == current)
        #expect(prepared.effectiveMatchesCanonical)
        #expect(prepared.domain.proposedContent.representations.last?.typeIdentifier.unicodeScalars.elementsEqual(composed.unicodeScalars) == true)
    }

    @Test
    func currentInheritanceRejectsAHiddenTypeInsteadOfRestoringCanonical() async throws {
        let canonical = try CanonicalContent(representations: [
            CanonicalRepresentation(content: ContentRepresentation(typeIdentifier: "a", bytes: Data([1])), fingerprint: ContentFingerprint(rawValue: 91)),
            CanonicalRepresentation(content: ContentRepresentation(typeIdentifier: "b", bytes: Data([2])), fingerprint: ContentFingerprint(rawValue: 92)),
        ])
        let source = snapshot(canonical: canonical, current: EffectiveContent(representations: [
            ContentRepresentation(typeIdentifier: "b", bytes: Data([2])),
        ]))
        let request = RevisionRequest(
            itemID: HistoryItemID(rawValue: UUID()), expected: source.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: "a", action: .inheritCurrent),
                RevisionDecision(typeIdentifier: "b", action: .inheritCurrent),
            ]))
        )
        await #expect(throws: HistoryFailure.invalidInput(.incoherentRevisionDraft)) {
            try await RevisionPreparationActor().prepare(request, from: source)
        }
    }

    private func request(_ item: HistoryItemReference, type: String, action: RevisionDecisionAction) -> RevisionRequest {
        RevisionRequest(itemID: item.id, expected: item.contentVersion, intent: .replace(RevisionDraft(decisions: [
            RevisionDecision(typeIdentifier: type, action: action),
        ])))
    }

    private func reference(from receipt: HistoryReceipt) throws -> HistoryItemReference {
        guard case .committed(let commit) = receipt else { throw HistoryFailure.persistence(.invariantViolation) }
        switch commit.outcome {
        case .inserted(let item), .revised(let item): return item
        default: throw HistoryFailure.persistence(.invariantViolation)
        }
    }

    private func snapshot(canonical: CanonicalContent, current: EffectiveContent) -> RevisionPreparationSnapshot {
        let revision = RevisionID(rawValue: UUID())
        return RevisionPreparationSnapshot(
            canonical: canonical, current: current,
            revisions: [RevisionRetentionSummary(id: revision, byteCount: current.representations.reduce(0) { $0 + $1.bytes.count })],
            activeRevisionID: revision, contentVersion: ContentVersion(rawValue: 2), revertedContent: nil
        )
    }
}
