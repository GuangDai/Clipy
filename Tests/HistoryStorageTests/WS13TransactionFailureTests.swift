/// WS13 — Transaction failure (docs/06-cross-cutting.md §8 WS13): inject a
/// failure inside the `ModelContext.transaction` closure AFTER row mutation
/// but BEFORE either singleton can advance. The failed attempt is inspected
/// immediately, before any successful write can repair or obscure residue:
/// every History row, retained-byte projection, position singleton, and
/// retention-config singleton remains byte/scalar exact; the public browse
/// and details reads still return the literal pre-attempt state; the rejected
/// ID is absent from both 1:1 tables; and the registered invalidation stream
/// is empty (docs/05-authority-kernel.md §10–§11, §14).
///
/// The package-internal value-typed Signature Index is compared directly
/// across the failure while the existing forced-collision capture seam also
/// proves its subsequent observable candidate behavior.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS13TransactionFailureTests {
    /// WS13 (docs/06-cross-cutting.md §8): closure failure commits no durable
    /// or derived state and publishes no invalidation. The failure oracle is
    /// complete before the first post-failure success; later captures are
    /// controls only and cannot hide a failed-attempt publish in a newest-one
    /// stream buffer.
    @Test func injectedClosureFailureCommitsNothingAndLeavesStoreAndIndexConsistent() async throws {
        let storeURL = WSSupport.tempStoreURL("ws13-transaction-failure")
        defer { WSSupport.removeStore(storeURL) }

        // Open the production facade once. `@testable` access is used only to
        // install WS13's one-shot injection on the facade's own Authority;
        // post-failure user-visible reads cross public `ClipboardHistory`.
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let authority = history.authority
        let preparation = IngestPreparationActor(
            fingerprint: ForcedCollisionFingerprint.digest(of:)
        )

        // All three values have the same type, fingerprint, and literal byte
        // count (16), but different bytes. Every later capture therefore
        // reaches byte-exact confirmation instead of passing through an empty
        // candidate set (D7; docs/02-domain.md §9.1–§9.2).
        let firstText = "ws13 seed item A"
        let secondText = "ws13 seed item B"
        let rejectedText = "ws13 seed item C"
        #expect(Set([Data(firstText.utf8).count, Data(secondText.utf8).count,
                     Data(rejectedText.utf8).count]) == [16])
        #expect(Set([firstText, secondText, rejectedText]).count == 3)

        let firstObservedAt = Date(timeIntervalSinceReferenceDate: 700_013_000)
        let secondObservedAt = Date(timeIntervalSinceReferenceDate: 700_013_100)
        let firstSource = "com.example.ws13.one"
        let secondSource = "com.example.ws13.two"

        let firstBundle = try await preparation.prepare(
            WSSupport.textCapture(
                firstText,
                observedAt: firstObservedAt,
                source: firstSource
            )
        )
        let firstReceipt = try await authority.commitCapture(firstBundle)
        guard case let .committed(firstCommit) = firstReceipt,
              case let .inserted(firstReference) = firstCommit.outcome
        else {
            Issue.record("WS13 seed A did not insert: \(firstReceipt)")
            return
        }
        #expect(firstCommit.position.rawValue == 1)

        let secondBundle = try await preparation.prepare(
            WSSupport.textCapture(
                secondText,
                observedAt: secondObservedAt,
                source: secondSource
            )
        )
        let secondReceipt = try await authority.commitCapture(secondBundle)
        guard case let .committed(secondCommit) = secondReceipt,
              case let .inserted(secondReference) = secondCommit.outcome
        else {
            Issue.record("WS13 seed B did not insert: \(secondReceipt)")
            return
        }
        #expect(secondCommit.position.rawValue == 2)
        #expect(firstReference.id != secondReference.id)

        // Capture a value-only baseline and release its assertion container
        // before the injected attempt. Every persisted column participates in
        // `Equatable`; no digest or implementation-derived summary is used.
        let before = try autoreleasepool {
            try TransactionStoreSnapshot.read(from: storeURL)
        }
        #expect(before.items.count == 2)
        #expect(Set(before.items.map(\.id)) == [
            firstReference.id.rawValue,
            secondReference.id.rawValue
        ])
        #expect(Set(before.items.map(\.contentVersionRaw)) == [1])
        #expect(Set(before.items.map(\.title)) == [firstText, secondText])
        #expect(Set(before.items.map(\.searchBody)) == [firstText, secondText])
        #expect(Set(before.items.map(\.firstCopiedAt)) == [firstObservedAt, secondObservedAt])
        #expect(Set(before.items.map(\.lastCopiedAt)) == [firstObservedAt, secondObservedAt])
        #expect(Set(before.items.map(\.copyCount)) == [1])
        #expect(Set(before.items.compactMap(\.firstSource)) == [firstSource, secondSource])
        #expect(Set(before.items.compactMap(\.lastSource)) == [firstSource, secondSource])
        #expect(
            Set(before.items.map(\.projectionSchemaVersion))
                == [ContentProjector.schemaVersion]
        )
        #expect(before.items.allSatisfy { $0.pinOrdinal == nil })
        for item in before.items {
            let expectedText = item.id == firstReference.id.rawValue
                ? firstText
                : secondText
            let canonical = try CanonicalBlobCodec.decode(item.canonicalBlob)
            #expect(
                canonical.representations.map(\.content.typeIdentifier)
                    == ["public.utf8-plain-text"]
            )
            #expect(canonical.representations.map(\.content.bytes) == [Data(expectedText.utf8)])
            let signatures = try SignatureBlobCodec.decode(item.canonicalSignatureBlob)
            #expect(signatures.map(\.typeIdentifier) == ["public.utf8-plain-text"])
            #expect(signatures.map(\.fingerprint.rawValue) == [
                ForcedCollisionFingerprint.collisionValue
            ])
            #expect(signatures.map(\.byteCount) == [16])
            #expect(
                try EffectiveTypeIdentifiersBlobCodec.decode(
                    item.effectiveTypeIdentifiersBlob
                ) == ["public.utf8-plain-text"]
            )
        }
        #expect(before.retainedBytes.count == 2)
        #expect(Set(before.retainedBytes.map(\.itemID)) == [
            firstReference.id.rawValue,
            secondReference.id.rawValue
        ])
        #expect(Set(before.retainedBytes.map(\.canonicalBytes)) == [16])
        #expect(Set(before.retainedBytes.map(\.revisionCount)) == [0])
        #expect(Set(before.retainedBytes.map(\.revisionBytes)) == [0])
        #expect(Set(before.retainedBytes.map(\.bytesSchemaVersion)) == [1])
        #expect(before.positions == [TransactionPositionSnapshot(
            key: "retained-history",
            rawValue: 2,
            maximumUnpinnedItems: 200
        )])
        #expect(before.configs == [TransactionConfigSnapshot(
            key: "retention-expansion",
            agePolicyEnabled: false,
            ageMaxSeconds: 0,
            storagePolicyEnabled: false,
            storageMaxBytes: 0,
            revisionPolicyEnabled: false,
            revisionMaxCount: nil,
            revisionMaxBytes: nil,
            configSchemaVersion: 1
        )])
        let beforeIndex = await authority.signatureIndex

        // Register before the failed attempt. This stream is closed and
        // drained immediately after the failure, before any successful write
        // can yield the same ChangePosition into bufferingNewest(1).
        let failedAttemptRegistration = await authority.registerInvalidationSubscriber()
        await authority.setTransactionFailureInjection(.beforeSingletonUpdate)

        let rejectedObservedAt = Date(timeIntervalSinceReferenceDate: 700_013_200)
        let rejectedBundle = try await preparation.prepare(
            WSSupport.textCapture(
                rejectedText,
                observedAt: rejectedObservedAt,
                source: "com.example.ws13.rejected"
            )
        )
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await authority.commitCapture(rejectedBundle)
        }

        // Public read oracle, before any successful mutation: failure cannot
        // be hidden merely because the raw rows rolled back. The newest-first
        // page and both full detail values must still expose exactly the two
        // literal seeds at position 2, with no rejected candidate visible.
        let publicPage = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 10
        ))
        #expect(publicPage.position.rawValue == 2)
        #expect(publicPage.next == nil)
        #expect(publicPage.rows.count == 2)
        #expect(publicPage.rows.map(\.item) == [secondReference, firstReference])

        let newestRow = try #require(publicPage.rows.first)
        #expect(newestRow.title == secondText)
        #expect(newestRow.typeIdentifiers == ["public.utf8-plain-text"])
        #expect(newestRow.lastCopiedAt == secondObservedAt)
        #expect(newestRow.copyCount == 1)
        #expect(newestRow.lastSource == secondSource)
        #expect(newestRow.pinnedPosition == nil)
        #expect(newestRow.search == nil)

        let oldestRow = try #require(publicPage.rows.last)
        #expect(oldestRow.title == firstText)
        #expect(oldestRow.typeIdentifiers == ["public.utf8-plain-text"])
        #expect(oldestRow.lastCopiedAt == firstObservedAt)
        #expect(oldestRow.copyCount == 1)
        #expect(oldestRow.lastSource == firstSource)
        #expect(oldestRow.pinnedPosition == nil)
        #expect(oldestRow.search == nil)

        let firstDetails = try await history.details(for: firstReference.id)
        #expect(firstDetails.item == firstReference)
        #expect(firstDetails.canonical.map(\.typeIdentifier) == ["public.utf8-plain-text"])
        #expect(firstDetails.canonical.map(\.bytes) == [Data(firstText.utf8)])
        #expect(firstDetails.effective.map(\.typeIdentifier) == ["public.utf8-plain-text"])
        #expect(firstDetails.effective.map(\.bytes) == [Data(firstText.utf8)])
        #expect(firstDetails.revisions.isEmpty)
        #expect(firstDetails.occurrence.firstCopiedAt == firstObservedAt)
        #expect(firstDetails.occurrence.lastCopiedAt == firstObservedAt)
        #expect(firstDetails.occurrence.count == 1)
        #expect(firstDetails.occurrence.firstSource == firstSource)
        #expect(firstDetails.occurrence.lastSource == firstSource)
        #expect(firstDetails.pinnedPosition == nil)

        let secondDetails = try await history.details(for: secondReference.id)
        #expect(secondDetails.item == secondReference)
        #expect(secondDetails.canonical.map(\.typeIdentifier) == ["public.utf8-plain-text"])
        #expect(secondDetails.canonical.map(\.bytes) == [Data(secondText.utf8)])
        #expect(secondDetails.effective.map(\.typeIdentifier) == ["public.utf8-plain-text"])
        #expect(secondDetails.effective.map(\.bytes) == [Data(secondText.utf8)])
        #expect(secondDetails.revisions.isEmpty)
        #expect(secondDetails.occurrence.firstCopiedAt == secondObservedAt)
        #expect(secondDetails.occurrence.lastCopiedAt == secondObservedAt)
        #expect(secondDetails.occurrence.count == 1)
        #expect(secondDetails.occurrence.firstSource == secondSource)
        #expect(secondDetails.occurrence.lastSource == secondSource)
        #expect(secondDetails.pinnedPosition == nil)

        await #expect(throws: HistoryFailure.notFound(rejectedBundle.domain.candidateID)) {
            try await history.details(for: rejectedBundle.domain.candidateID)
        }

        // Immediate rollback oracle: compare every field of all four durable
        // row classes before allowing any successful operation. Separately
        // assert the rejected business ID is absent from both sides of the
        // mandatory HistoryItemRow ↔ RetainedBytesRow 1:1 projection.
        let afterFailure = try autoreleasepool {
            try TransactionStoreSnapshot.read(from: storeURL)
        }
        #expect(afterFailure.items == before.items)
        #expect(afterFailure.retainedBytes == before.retainedBytes)
        #expect(afterFailure.positions == before.positions)
        #expect(afterFailure.configs == before.configs)
        #expect(await authority.signatureIndex == beforeIndex)
        #expect(!afterFailure.items.map(\.id).contains(rejectedBundle.domain.candidateID.rawValue))
        #expect(
            !afterFailure.retainedBytes.map(\.itemID)
                .contains(rejectedBundle.domain.candidateID.rawValue)
        )

        await authority.unregisterInvalidationSubscriber(
            failedAttemptRegistration.subscription
        )
        var failedAttemptInvalidations: [HistoryInvalidation] = []
        for try await invalidation in failedAttemptRegistration.stream {
            failedAttemptInvalidations.append(invalidation)
        }
        #expect(failedAttemptInvalidations.isEmpty)

        // Signature-Index behavioral control, only after every rollback and
        // zero-publish assertion above: retry the exact failed prepared value.
        // It must insert its original candidate ID at the next position;
        // forced-equal fingerprints with both seeds must not coalesce without
        // byte equality. A dedicated subscription proves this success emits
        // exactly its own position, independently of the failed attempt.
        let retryRegistration = await authority.registerInvalidationSubscriber()
        let retryReceipt = try await authority.commitCapture(rejectedBundle)
        guard case let .committed(retryCommit) = retryReceipt,
              case let .inserted(retryReference) = retryCommit.outcome
        else {
            Issue.record("WS13 retry did not insert: \(retryReceipt)")
            return
        }
        #expect(retryCommit.position.rawValue == 3)
        #expect(retryReference.id == rejectedBundle.domain.candidateID)
        await authority.unregisterInvalidationSubscriber(retryRegistration.subscription)
        var retryInvalidations: [HistoryInvalidation] = []
        for try await invalidation in retryRegistration.stream {
            retryInvalidations.append(invalidation)
        }
        #expect(retryInvalidations.map(\.latestPosition.rawValue) == [3])

        // Once the successful insert has legitimately updated the index, a
        // new equal-content capture coalesces the retried row — not either
        // forced-collision seed — and advances exactly once more.
        let equalBundle = try await preparation.prepare(
            WSSupport.textCapture(
                rejectedText,
                observedAt: Date(timeIntervalSinceReferenceDate: 700_013_300)
            )
        )
        let equalReceipt = try await authority.commitCapture(equalBundle)
        guard case let .committed(equalCommit) = equalReceipt,
              case let .coalesced(winner) = equalCommit.outcome
        else {
            Issue.record("WS13 equal-content control did not coalesce: \(equalReceipt)")
            return
        }
        #expect(equalCommit.position.rawValue == 4)
        #expect(winner.id == retryReference.id)
    }
}
