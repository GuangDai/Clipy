/// Canonical-state detail DTOs can share their immutable representation array
/// after full lineage validation. A revision must still project its own bytes,
/// including hidden types, without changing previously returned values (05 §14.3).
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct DetailsCanonicalProjectionTests {
    @Test func canonicalAndEffectiveStayIndependentAcrossRevisionAndRevert() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let textType = "public.utf8-plain-text"
        let opaqueType = "com.example.details.opaque"
        let binaryType = "dyn.details.binary"
        let originalText = Data("Original title\nbody".utf8)
        let originalBinary = Data([0x00, 0xFF, 0x80])
        let opaqueBytes = Data([0x00])
        // Deliberately not in the canonical type order; include a raw NUL
        // and opaque bytes so neither projection can substitute text semantics.
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: textType, bytes: originalText),
                CapturedRepresentation(typeIdentifier: opaqueType, bytes: opaqueBytes),
                CapturedRepresentation(typeIdentifier: binaryType, bytes: originalBinary),
            ],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_030_400)
        )))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome else {
            Issue.record("Expected an inserted item")
            return
        }

        let initial = try await history.details(for: reference.id)
        #expect(initial.item == reference)
        #expect(initial.revisions.isEmpty)
        #expect(initial.canonical.map(\.typeIdentifier) == [opaqueType, binaryType, textType])
        #expect(initial.canonical.map(\.bytes) == [opaqueBytes, originalBinary, originalText])
        #expect(initial.effective == initial.canonical)

        let replacement = Data("Replacement title".utf8)
        _ = try await history.perform(.revise(RevisionRequest(
            itemID: reference.id,
            expected: initial.item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: textType, action: .replace(bytes: replacement)),
                RevisionDecision(typeIdentifier: opaqueType, action: .inheritCanonical),
                RevisionDecision(typeIdentifier: binaryType, action: .hide),
            ]))
        )))
        let revised = try await history.details(for: reference.id)
        #expect(revised.canonical == initial.canonical)
        #expect(revised.effective.map(\.typeIdentifier) == [opaqueType, textType])
        #expect(revised.effective.map(\.bytes) == [opaqueBytes, replacement])
        #expect(revised.revisions.count == 1)
        #expect(revised.revisions.first?.typeIdentifiers == [opaqueType, textType])
        #expect(revised.revisions.first?.byteCount == opaqueBytes.count + replacement.count)

        _ = try await history.perform(.revise(RevisionRequest(
            itemID: reference.id,
            expected: revised.item.contentVersion,
            intent: .revert(to: .canonical)
        )))
        let reverted = try await history.details(for: reference.id)
        #expect(reverted.canonical == initial.canonical)
        #expect(reverted.effective == initial.canonical)
        #expect(reverted.revisions.count == 2)
        #expect(reverted.revisions.last?.isActive == true)
        #expect(reverted.revisions.last?.typeIdentifiers == [opaqueType, binaryType, textType])
        #expect(reverted.revisions.last?.byteCount == opaqueBytes.count + originalText.count + originalBinary.count)

        // The earlier detail values retain their own content after both writes.
        #expect(initial.effective.map(\.bytes) == [opaqueBytes, originalBinary, originalText])
        #expect(revised.effective.map(\.bytes) == [opaqueBytes, replacement])
    }
}
