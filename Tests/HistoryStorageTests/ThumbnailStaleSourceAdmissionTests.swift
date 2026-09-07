import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct ThumbnailStaleSourceAdmissionTests {
    @Test(arguments: [false, true])
    func staleReferenceStopsBeforePayloadAccessAndCurrentReadsOnlyItsCandidate(hasImage: Bool) async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let image = Data(repeating: 0xAB, count: 128 * 1_024)
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            "before", observedAt: Date(timeIntervalSinceReferenceDate: 850_000_000),
            extra: hasImage ? [(typeIdentifier: "public.png", bytes: Array(image))] : []
        )))
        guard case .committed(let commit) = receipt, case .inserted(let original) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        var decisions = [RevisionDecision(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data("after".utf8)))]
        if hasImage {
            decisions.append(RevisionDecision(typeIdentifier: "public.png", action: .inheritCanonical))
        }
        let revisionReceipt = try await history.perform(.revise(RevisionRequest(
            itemID: original.id, expected: original.contentVersion,
            intent: .replace(RevisionDraft(decisions: decisions))
        )))
        guard case .committed(let revisionCommit) = revisionReceipt,
              case .revised(let current) = revisionCommit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let damagedType = hasImage ? "public.png" : "public.utf8-plain-text"
        try await history.authority.makePayloadUnavailable(
            itemID: current.id, revisionOrdinal: 1, typeIdentifier: damagedType
        )
        let pixels = PixelSize(width: 32, height: 32)
        await #expect(throws: HistoryFailure.staleContent(
            expected: original.contentVersion, current: current.contentVersion
        )) {
            try await history.authority.thumbnailSource(for: original, pixels: pixels)
        }
        if hasImage {
            await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                try await history.authority.thumbnailSource(for: current, pixels: pixels)
            }
        } else {
            #expect(try await history.authority.thumbnailSource(for: current, pixels: pixels) == nil)
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.representation(HistoryRepresentationRequest(
                item: current, basis: .effective, typeIdentifier: damagedType
            ))
        }
    }

    @Test func missingItemAndInvalidPixelSizeStayTyped() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let item = HistoryItemReference(id: HistoryItemID(rawValue: UUID()), contentVersion: .initial)
        await #expect(throws: HistoryFailure.invalidInput(.invalidPixelSize)) {
            try await history.authority.thumbnailSource(for: item, pixels: PixelSize(width: 0, height: 32))
        }
        await #expect(throws: HistoryFailure.notFound(item.id)) {
            try await history.authority.thumbnailSource(for: item, pixels: PixelSize(width: 32, height: 32))
        }
    }
}
