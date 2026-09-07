/// The real editor draft's Keep Current request stays a no-op even when the
/// retained revision count is full. Opaque and hidden siblings are independent
/// values, not text to decode/re-encode or restore from Canonical implicitly.
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct EditorNoChangeAtRevisionCapacityTests {
    @Test func keepCurrentAtBothPolicyThresholdsDoesNotPruneAnInactiveRevision() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let type = "public.utf8-plain-text"
        let capture = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: type, bytes: Data("original".utf8))],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_093_200)
        )))
        guard case let .committed(captureCommit) = capture,
              case let .inserted(initial) = captureCommit.outcome else {
            Issue.record("expected a captured policy-threshold fixture")
            return
        }
        var current = initial
        for text in ["one", "two"] {
            let receipt = try await history.perform(.revise(RevisionRequest(
                itemID: current.id, expected: current.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(typeIdentifier: type, action: .replace(bytes: Data(text.utf8))),
                ]))
            )))
            guard case let .committed(commit) = receipt,
                  case let .revised(reference) = commit.outcome else {
                Issue.record("expected two distinct retained revisions")
                return
            }
            current = reference
        }
        _ = try await history.perform(.setRetentionPolicies(HistoryRetentionPolicies(
            age: nil, storage: nil,
            revisions: RevisionRetention(maxRevisionsPerItem: 2, maxRevisionBytesPerItem: 6)
        )))
        let before = try await history.details(for: current.id)
        let canonicalBefore = try await representations(before.canonical, basis: .canonical, item: current, in: history)
        let effectiveBefore = try await representations(before.effective, basis: .effective, item: current, in: history)
        let usageBefore = try await history.usage()
        #expect(before.revisions.count == 2)
        #expect(before.revisions.map(\.isActive) == [false, true])
        #expect(usageBefore.revisionBytes == 6)
        let draft = ReviseEditorDraft(details: before)
        let receipt = try await history.perform(.revise(draft.revisionRequest()))
        guard case .unchanged = receipt else {
            Issue.record("a no-op must not apply speculative append-time pruning")
            return
        }
        #expect(try await history.details(for: current.id) == before)
        #expect(try await history.usage() == usageBefore)
        #expect(try await representations(before.canonical, basis: .canonical, item: current, in: history) == canonicalBefore)
        #expect(try await representations(before.effective, basis: .effective, item: current, in: history) == effectiveBefore)
    }

    @Test func keepCurrentAtFullCapacityPreservesEveryEffectiveByteAndHistoryToken() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let textType = "public.utf8-plain-text"
        let opaqueType = "com.example.binary"
        let hiddenType = "com.example.hidden"
        let originals = [
            CapturedRepresentation(typeIdentifier: textType, bytes: Data("original".utf8)),
            CapturedRepresentation(typeIdentifier: opaqueType, bytes: Data([0x00, 0xFF])),
            CapturedRepresentation(typeIdentifier: hiddenType, bytes: Data([0x7F])),
        ]
        let captured = try await history.perform(.capture(ClipboardCapture(
            representations: originals,
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_093_100)
        )))
        guard case let .committed(captureCommit) = captured,
              case let .inserted(initial) = captureCommit.outcome else {
            Issue.record("expected a captured editor fixture")
            return
        }
        var current = initial
        let maximum = HistoryLimits.standard.maximumRevisionsPerItem
        for index in 1...maximum {
            let receipt = try await history.perform(.revise(RevisionRequest(
                itemID: current.id, expected: current.contentVersion,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(typeIdentifier: textType, action: .replace(bytes: Data("revision \(index)".utf8))),
                    RevisionDecision(typeIdentifier: opaqueType, action: .replace(bytes: Data([0x00, 0xFF]) + Data("\(index)".utf8))),
                    RevisionDecision(typeIdentifier: hiddenType, action: .hide),
                ]))
            )))
            guard case let .committed(commit) = receipt,
                  case let .revised(reference) = commit.outcome else {
                Issue.record("expected each capacity-filling revision to change bytes")
                return
            }
            current = reference
        }
        let before = try await history.details(for: current.id)
        let effectiveBefore = try await representations(before.effective, basis: .effective, item: current, in: history)
        let usageBefore = try await history.usage()
        #expect(before.revisions.count == maximum)
        #expect(before.item.contentVersion.rawValue == UInt64(maximum + 1))
        let draft = ReviseEditorDraft(details: before)
        #expect(!draft.isDirty && draft.canSubmit)
        let request = draft.revisionRequest()
        #expect(request.itemID == current.id && request.expected == current.contentVersion)
        guard case let .replace(proposal) = request.intent else {
            Issue.record("editor must submit a complete replacement decision set")
            return
        }
        let actions = Dictionary(uniqueKeysWithValues: proposal.decisions.map { ($0.typeIdentifier, $0.action) })
        #expect(actions[textType] == .inheritCurrent)
        #expect(actions[opaqueType] == .inheritCurrent)
        #expect(actions[hiddenType] == .hide)
        #expect(draft.replacementRequest(for: opaqueType) == nil)
        #expect(!draft.hasReplacementSource(for: opaqueType))
        #expect(effectiveBefore.first { $0.typeIdentifier == opaqueType }?.bytes
            == Data([0x00, 0xFF]) + Data("\(maximum)".utf8))

        let unchanged = try await history.perform(.revise(request))
        guard case .unchanged = unchanged else {
            Issue.record("unchanged editor Save consumes no revision capacity")
            return
        }
        var changedDraft = draft
        let sourceRequest = try #require(changedDraft.replacementRequest(for: textType))
        #expect(sourceRequest == HistoryRepresentationRequest(item: current, basis: .effective, typeIdentifier: textType))
        let source = try await history.representation(sourceRequest)
        #expect(source.bytes == Data("revision \(maximum)".utf8))
        let installed = changedDraft.installReplacementSource(source)
        #expect(installed)
        #expect(!changedDraft.hasReplacementSource(for: opaqueType))
        changedDraft.setChoice(.replace, for: textType)
        // Merely opening Replace must still submit byte-identical current
        // text as a no-op, even when appending would exceed revision capacity.
        let loadedButUnedited = try await history.perform(.revise(changedDraft.revisionRequest()))
        guard case .unchanged = loadedButUnedited else {
            Issue.record("an explicitly loaded but unedited replacement consumes no revision capacity")
            return
        }
        changedDraft.setReplacementText("a genuinely new revision", for: textType)
        let changedRequest = changedDraft.revisionRequest()
        await #expect(throws: HistoryFailure.capacityExceeded(.revisionCount)) {
            try await history.perform(.revise(changedRequest))
        }
        let after = try await history.details(for: current.id)
        #expect(after == before)
        #expect(try await history.usage() == usageBefore)
        let payload = try await history.pastePayload(for: current.id)
        #expect(payload.item == current)
        #expect(payload.representations == effectiveBefore)
        #expect(!payload.representations.contains { $0.typeIdentifier == hiddenType })
        let canonicalAfter = try await representations(after.canonical, basis: .canonical, item: current, in: history)
        #expect(canonicalAfter.map(\.bytes) == [Data([0x00, 0xFF]), Data([0x7F]), Data("original".utf8)])
        #expect(try await representations(after.effective, basis: .effective, item: current, in: history) == effectiveBefore)
    }

    /// Payload assertions explicitly read each selected representation from
    /// the real store; these oracle bytes never become editor draft inputs.
    private func representations(
        _ metadata: [HistoryRepresentationMetadata], basis: HistoryContentBasis,
        item: HistoryItemReference, in history: SQLiteHistory
    ) async throws -> [HistoryRepresentation] {
        var values: [HistoryRepresentation] = []
        for representation in metadata {
            values.append(try await history.representation(HistoryRepresentationRequest(
                item: item, basis: basis, typeIdentifier: representation.typeIdentifier
            )))
        }
        return values
    }
}
