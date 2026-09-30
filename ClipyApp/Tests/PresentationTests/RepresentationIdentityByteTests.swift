import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import ClipyApp

@MainActor
struct RepresentationIdentityByteTests {
    @Test func canonicallyEquivalentTypeSpellingsKeepIndependentDraftAndExportState() async throws {
        let firstType = "com.example.\u{00E9}"
        let secondType = "com.example.e\u{0301}"
        #expect(firstType == secondType, "Swift String equality would conflate these two exact identifiers")
        let firstIdentity = RepresentationIdentity(typeIdentifier: firstType)
        let secondIdentity = RepresentationIdentity(typeIdentifier: secondType)
        #expect(Set([firstIdentity, secondIdentity]).count == 2)

        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [
                .init(typeIdentifier: firstType, bytes: Data([1])),
                .init(typeIdentifier: secondType, bytes: Data([2])),
            ], origin: .init(sourceApplication: nil, lineageHint: nil), observedAt: Date()
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let opening = try await history.details(for: item.id)
        var draft = ReviseEditorDraft(details: opening)
        draft.setChoice(.hide, for: firstType)
        #expect(draft.choice(for: firstType) == .hide)
        #expect(draft.choice(for: secondType) == .keepCurrent)
        #expect(draft.canSubmit)
        _ = try await history.perform(.revise(draft.revisionRequest()))
        let revised = try await history.details(for: item.id)
        #expect(revised.effective.count == 1)
        #expect(revised.effective.first?.representationIdentity == secondIdentity)
        #expect(ContentBasis.effective.representation(typeIdentifier: firstType, in: revised) == nil)
        let firstExport = try #require(ContentBasis.canonical.representation(typeIdentifier: firstType, in: revised))
        let secondExport = try #require(ContentBasis.canonical.representation(typeIdentifier: secondType, in: revised))
        #expect(try await history.representation(firstExport).bytes == Data([1]))
        #expect(try await history.representation(secondExport).bytes == Data([2]))
    }
}
