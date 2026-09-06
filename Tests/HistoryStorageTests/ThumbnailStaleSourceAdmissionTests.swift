import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

private enum ThumbnailSourceDamage: Sendable {
    case canonical
    case revisions
    case signature
}

struct ThumbnailStaleSourceAdmissionTests {
    /// Old references need only a scalar version rejection. Poison each
    /// content codec independently to distinguish that path from hydrating
    /// first; the same current reference must still reject the real damage.
    @Test(arguments: [ThumbnailSourceDamage.canonical, .revisions, .signature])
    fileprivate func staleCreatorRejectsBeforeContentDecodeButCurrentCreatorStillValidates(
        damage: ThumbnailSourceDamage
    ) async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let captureReceipt = try await history.perform(.capture(WSSupport.textCapture(
            "before", observedAt: Date(timeIntervalSinceReferenceDate: 850_000_000)
        )))
        guard case .committed(let captureCommit) = captureReceipt,
              case .inserted(let original) = captureCommit.outcome else {
            Issue.record("Expected the original item")
            return
        }
        let revisionReceipt = try await history.perform(.revise(RevisionRequest(
            itemID: original.id,
            expected: original.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.utf8-plain-text",
                action: .replace(bytes: Data("after".utf8))
            )]))
        )))
        guard case .committed(let revisionCommit) = revisionReceipt,
              case .revised(let current) = revisionCommit.outcome else {
            Issue.record("Expected a different current content version")
            return
        }
        let pixels = PixelSize(width: 32, height: 32)

        // Current valid reads still hydrate and return values that remain
        // usable after their operation-local autorelease pools have drained.
        #expect(try await history.thumbnail(for: current, pixels: pixels) == nil)
        let details = try await history.details(for: current.id)
        let paste = try await history.pastePayload(for: current.id)
        #expect(details.canonical.first?.bytes == Data("before".utf8))
        #expect(details.effective.first?.bytes == Data("after".utf8))
        #expect(paste.representations == details.effective)

        try await history.authority.damageThumbnailSource(current.id, damage: damage)
        await #expect(throws: HistoryFailure.staleContent(
            expected: original.contentVersion, current: current.contentVersion
        )) {
            // There is no existing flight: this exercises creator admission.
            try await history.thumbnail(for: original, pixels: pixels)
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.thumbnail(for: current, pixels: pixels)
        }
    }
}

private extension HistoryAuthority {
    func damageThumbnailSource(
        _ id: HistoryItemID,
        damage: ThumbnailSourceDamage
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let row = try #require(try HistoryItemRowHydration.fetchRow(businessID: id, in: context))
        try context.transaction {
            switch damage {
            case .canonical:
                row.canonicalBlob = Data([0xFF])
            case .revisions:
                row.revisionStateBlob = Data([0xFF])
            case .signature:
                row.canonicalSignatureBlob = Data([0xFF])
            }
        }
    }
}
