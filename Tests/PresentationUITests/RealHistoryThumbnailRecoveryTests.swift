/// A real stored malformed image becomes a surface-local unavailable result;
/// a byte-changing revision can subsequently produce a thumbnail for its new
/// exact reference. No scripted History failure or replacement writer is used.
import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import PresentationUI

@MainActor
struct RealHistoryThumbnailRecoveryTests {
    @Test func validImageRevisionRecoversWithoutReusingTheOldUnavailableResult() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let malformed = Data("not a PNG image".utf8)
        let capture = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(typeIdentifier: "public.png", bytes: malformed)],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_070_000)
        )))
        guard case let .committed(captureCommit) = capture,
              case let .inserted(original) = captureCommit.outcome else {
            Issue.record("Expected opaque PNG bytes to be captured")
            return
        }
        let store = ThumbnailStore(history: history)
        #expect(!store.isUnavailable(for: original))
        store.prefetch(original)
        try #require(await pollUntil { store.inFlightCount == 0 })
        #expect(store.isUnavailable(for: original))
        #expect(store.imagePixelSize(for: original) == nil)
        #expect(store.cachedEntryCount == 1)
        #expect(store.cachedDecodedBytes == 0)

        let validPNG = fixturePNGData
        let revision = try await history.perform(.revise(RevisionRequest(
            itemID: original.id, expected: original.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: "public.png", action: .replace(bytes: validPNG)
            )]))
        )))
        guard case let .committed(revisionCommit) = revision,
              case let .revised(revised) = revisionCommit.outcome else {
            Issue.record("Expected valid PNG bytes to append a content revision")
            return
        }
        #expect(revised.id == original.id)
        #expect(revised.contentVersion.rawValue == 2)
        #expect(!store.isUnavailable(for: revised))
        store.prefetch(revised)
        try #require(await pollUntil { store.imagePixelSize(for: revised) != nil })
        #expect(store.imagePixelSize(for: revised) == PixelSize(width: 1, height: 1))
        #expect(!store.isUnavailable(for: revised))
        #expect(store.isUnavailable(for: original))
        #expect(store.imagePixelSize(for: original) == nil)
        #expect(store.cachedEntryCount == 2)
        let decodedBytes = store.cachedDecodedBytes
        #expect(decodedBytes > 0)

        // Receipt-driven revision purge retires only the old reference. It
        // cannot erase a new-version thumbnail that already completed.
        store.purge(.revision(old: original, new: revised))
        #expect(!store.isUnavailable(for: original))
        #expect(store.imagePixelSize(for: original) == nil)
        #expect(!store.isUnavailable(for: revised))
        #expect(store.imagePixelSize(for: revised) == PixelSize(width: 1, height: 1))
        #expect(store.cachedEntryCount == 1)
        #expect(store.cachedDecodedBytes == decodedBytes)

        // A later stale request crosses the real Authority version fence and
        // must not become a new unavailable entry for the retired reference.
        store.prefetch(original)
        try #require(await pollUntil { store.inFlightCount == 0 })
        #expect(!store.isUnavailable(for: original))
        #expect(store.cachedEntryCount == 1)
        #expect(store.cachedDecodedBytes == decodedBytes)

        let details = try await history.details(for: original.id)
        #expect(details.item == revised)
        #expect(details.canonical.map(\.typeIdentifier) == ["public.png"])
        #expect(details.effective.map(\.typeIdentifier) == ["public.png"])
        let canonical = try await history.representation(HistoryRepresentationRequest(
            item: revised, basis: .canonical, typeIdentifier: "public.png"
        ))
        let effective = try await history.representation(HistoryRepresentationRequest(
            item: revised, basis: .effective, typeIdentifier: "public.png"
        ))
        #expect(canonical == HistoryRepresentation(typeIdentifier: "public.png", bytes: malformed))
        #expect(effective == HistoryRepresentation(typeIdentifier: "public.png", bytes: validPNG))
        let paste = try await history.pastePayload(for: original.id)
        #expect(paste.item == revised)
        #expect(paste.representations.map(\.bytes) == [validPNG])
    }
}
