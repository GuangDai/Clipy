/// Details describe Canonical and Effective representations without payloads.
/// Explicit version-bound reads retain byte-exact revision/revert evidence,
/// including hidden types and previously returned values (05 §14.3).
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct DetailsCanonicalProjectionTests {
    @Test func canonicalAndEffectiveStayIndependentAcrossRevisionAndRevert() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
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
        #expect(initial.canonical.map(\.byteCount) == [opaqueBytes.count, originalBinary.count, originalText.count])
        #expect(initial.effective == initial.canonical)
        #expect(initial.effectiveMatchesCanonical)
        let initialCanonical = try await read(initial, basis: .canonical, in: history)
        let initialEffective = try await read(initial, basis: .effective, in: history)
        #expect(initialCanonical.map(\.bytes) == [opaqueBytes, originalBinary, originalText])
        #expect(initialEffective == initialCanonical)

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
        #expect(revised.effective.map(\.byteCount) == [opaqueBytes.count, replacement.count])
        #expect(!revised.effectiveMatchesCanonical)
        let revisedCanonical = try await read(revised, basis: .canonical, in: history)
        let revisedEffective = try await read(revised, basis: .effective, in: history)
        #expect(revisedCanonical == initialCanonical)
        #expect(revisedEffective.map(\.bytes) == [opaqueBytes, replacement])
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
        #expect(reverted.effectiveMatchesCanonical)
        #expect(try await read(reverted, basis: .canonical, in: history) == initialCanonical)
        #expect(try await read(reverted, basis: .effective, in: history) == initialCanonical)
        #expect(reverted.revisions.count == 2)
        #expect(reverted.revisions.last?.isActive == true)
        #expect(reverted.revisions.last?.typeIdentifiers == [opaqueType, binaryType, textType])
        #expect(reverted.revisions.last?.byteCount == opaqueBytes.count + originalText.count + originalBinary.count)

        // Previously returned metadata and explicit payloads remain immutable.
        #expect(initial.effective.map(\.byteCount) == [opaqueBytes.count, originalBinary.count, originalText.count])
        #expect(revised.effective.map(\.byteCount) == [opaqueBytes.count, replacement.count])
        #expect(initialEffective.map(\.bytes) == [opaqueBytes, originalBinary, originalText])
        #expect(revisedEffective.map(\.bytes) == [opaqueBytes, replacement])
    }

    @Test func equalRepresentationMetadataDoesNotImplyEqualContent() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let receipt = try await history.perform(.capture(WSSupport.textCapture("aaaa", observedAt: Date(timeIntervalSinceReferenceDate: 1000))))
        guard case let .committed(commit) = receipt, case let .inserted(item) = commit.outcome else {
            Issue.record("Expected an inserted item")
            return
        }
        _ = try await history.perform(.revise(.init(
            itemID: item.id, expected: item.contentVersion,
            intent: .replace(.init(decisions: [.init(
                typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data("bbbb".utf8))
            )]))
        )))
        let details = try await history.details(for: item.id)
        #expect(details.canonical == details.effective)
        #expect(!details.effectiveMatchesCanonical)
        let canonical = try await read(details, basis: .canonical, in: history)
        let effective = try await read(details, basis: .effective, in: history)
        #expect(canonical.map(\.bytes) == [Data("aaaa".utf8)])
        #expect(effective.map(\.bytes) == [Data("bbbb".utf8)])
    }

    private func read(
        _ details: HistoryDetails, basis: HistoryContentBasis, in history: SQLiteHistory
    ) async throws -> [HistoryRepresentation] {
        let metadata = basis == .canonical ? details.canonical : details.effective
        var values: [HistoryRepresentation] = []
        for representation in metadata {
            values.append(try await history.representation(.init(
                item: details.item, basis: basis, typeIdentifier: representation.typeIdentifier
            )))
        }
        return values
    }
}
