/// Transaction boundary proof (docs/06-cross-cutting.md §7 item 1): closure
/// success durably commits item mutations and the singleton position once,
/// with no extra `save()`; closure failure commits neither.
/// Owning spec: docs/05-authority-kernel.md §10 (the only durable History
/// Commit primitive is `ModelContext.transaction`; "closure success is the
/// save boundary", "closure failure commits nothing"), §16 (ordinary
/// closure failures map to `.persistence(.transaction)`); WS13 durable half:
/// docs/06-cross-cutting.md §8. A proved Cocoa out-of-space/POSIX ENOSPC
/// closure failure is the narrower retryable exception (docs/05 §16).
///
/// The one-shot transaction-failure seam
/// (`setTransactionFailureInjection` /
/// `InjectedTransactionFailure.beforeSingletonUpdate`) is an @testable-only
/// knob on `HistoryAuthority`. The failure test opens the production facade
/// and arms its own Authority, then proves rollback both through public
/// `browse` / `details` and through an INDEPENDENT fresh `ModelContainer`
/// over the same on-disk store. The Authority's operation-local contexts
/// have autosave disabled and the kernel calls no
/// `save()`/`processPendingChanges()`/`rollback()` (§10), so anything a
/// fresh container sees was committed by the transaction closure itself.
import Foundation
import SwiftData
import Testing
@testable import HistoryStorage
import HistoryCore

struct TransactionBoundaryProofTests {
    /// §7 item 1, SUCCESS path: one capture commit durably persists BOTH the
    /// item row AND the singleton position (0 → 1) inside the transaction
    /// closure — proven by immediate visibility from a fresh independent
    /// container, with no extra save call in the kernel (§10).
    @Test func closureSuccessDurablyCommitsItemAndSingletonWithoutExtraSave() async throws {
        let url = WSSupport.tempStoreURL("tx-boundary-success")
        defer { WSSupport.removeStore(url) }

        let authority = try await WSSupport.makeAuthority(storeURL: url)
        let preparation = IngestPreparationActor()

        let observedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let text = "tx-boundary success capture"
        let bundle = try await preparation.prepare(
            WSSupport.textCapture(text, observedAt: observedAt)
        )

        let receipt = try await authority.commitCapture(bundle)

        // §9/§3.2: the singleton starts at position 0, so the first History
        // Commit mints exactly one checked successor — position 1.
        guard case .committed(let commit) = receipt else {
            Issue.record("expected a .committed receipt, got \(receipt)")
            return
        }
        #expect(commit.position.rawValue == 1)
        guard case .inserted(let reference) = commit.outcome else {
            Issue.record("expected an .inserted outcome, got \(commit.outcome)")
            return
        }
        #expect(reference.contentVersion.rawValue == 1)

        // §7 item 1 proof: a FRESH independent container over the same store
        // file sees the commit immediately. The kernel performs no trailing
        // save (§10: "Closure success is the save boundary"), so durability
        // here is the transaction closure's own doing.
        let verification = try WSSupport.makeContainer(storeURL: url)
        let rows = try WSSupport.fetchRows(verification)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.id == reference.id.rawValue)
        #expect(row.contentVersionRaw == 1)
        #expect(row.title == text)
        #expect(row.copyCount == 1)
        #expect(row.firstCopiedAt == observedAt)
        #expect(row.lastCopiedAt == observedAt)
        #expect(row.pinOrdinal == nil)

        // The singleton moved exactly once, in the same transaction (§10,
        // D6): item mutation and position update are durable together.
        let position = try WSSupport.fetchPosition(verification)
        #expect(position.rawValue == 1)
    }

    /// §7 item 1, FAILURE path: with the one-shot
    /// `.beforeSingletonUpdate` injection armed, the commit throws
    /// `.persistence(.transaction)` (§16) and the durable state is EXACTLY
    /// the pre-attempt state — the injected failure fires after all row
    /// mutations but before the singleton update, and §10's "closure failure
    /// commits nothing" means NEITHER side persisted.
    @Test func injectedFailureBeforeSingletonUpdateCommitsNeitherRowsNorPosition() async throws {
        let url = WSSupport.tempStoreURL("tx-boundary-failure")
        defer { WSSupport.removeStore(url) }

        // The real facade owns the injected Authority. Only injection/setup
        // crosses @testable; the post-failure behavior proof uses its public
        // ClipboardHistory read methods.
        let history = try await WSSupport.openHistory(storeURL: url)
        let authority = history.authority
        let preparation = IngestPreparationActor()

        // Pre-attempt durable state: one committed item, position 1.
        let firstText = "tx-boundary committed first"
        let firstBundle = try await preparation.prepare(
            WSSupport.textCapture(
                firstText,
                observedAt: Date(timeIntervalSinceReferenceDate: 2_000)
            )
        )
        let firstReceipt = try await authority.commitCapture(firstBundle)
        guard case .committed(let firstCommit) = firstReceipt,
              case .inserted(let firstReference) = firstCommit.outcome
        else {
            Issue.record("setup commit did not insert: \(firstReceipt)")
            return
        }
        #expect(firstCommit.position.rawValue == 1)

        // Freeze every persisted column before the failed attempt. The
        // snapshot is value-only and its independent container is released
        // before the transaction injection is armed.
        let before = try autoreleasepool {
            try TransactionStoreSnapshot.read(from: url)
        }
        #expect(before.items.count == 1)
        #expect(before.items.map(\.id) == [firstReference.id.rawValue])
        #expect(before.items.map(\.title) == [firstText])
        #expect(before.items.map(\.contentVersionRaw) == [1])
        #expect(before.items.map(\.copyCount) == [1])
        #expect(before.retainedBytes == [TransactionRetainedBytesSnapshot(
            itemID: firstReference.id.rawValue,
            canonicalBytes: 27,
            revisionCount: 0,
            revisionBytes: 0,
            bytesSchemaVersion: 1
        )])
        #expect(before.positions == [TransactionPositionSnapshot(
            key: "retained-history",
            rawValue: 1,
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

        // This subscriber belongs only to the failed attempt. Closing and
        // draining it before any later success makes a false publish directly
        // observable even though production buffering keeps only the newest
        // invalidation.
        let failedAttemptRegistration = await authority.registerInvalidationSubscriber()

        // Roadmap-owned WS13 seam: the next transaction closure entered
        // throws after row mutation, before the singleton update.
        await authority.setTransactionFailureInjection(.beforeSingletonUpdate)

        let rejectedText = "tx-boundary rejected second"
        let rejectedBundle = try await preparation.prepare(
            WSSupport.textCapture(
                rejectedText,
                observedAt: Date(timeIntervalSinceReferenceDate: 2_100)
            )
        )

        // §16: the caller observes the transaction-closure failure as
        // `.persistence(.transaction)` (WS13).
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await authority.commitCapture(rejectedBundle)
        }

        // Public boundary proof immediately after the throw and before any
        // successful mutation: the rejected row is absent, the position is
        // still 1, and the seed's literal projections and content are intact.
        let publicPage = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 10
        ))
        #expect(publicPage.position.rawValue == 1)
        #expect(publicPage.next == nil)
        #expect(publicPage.rows.count == 1)
        let publicRow = try #require(publicPage.rows.first)
        #expect(publicRow.item == firstReference)
        #expect(publicRow.title == firstText)
        #expect(publicRow.typeIdentifiers == ["public.utf8-plain-text"])
        #expect(publicRow.lastCopiedAt == Date(timeIntervalSinceReferenceDate: 2_000))
        #expect(publicRow.copyCount == 1)
        #expect(publicRow.lastSource == nil)
        #expect(publicRow.pinnedPosition == nil)
        #expect(publicRow.search == nil)

        let publicDetails = try await history.details(for: firstReference.id)
        #expect(publicDetails.item == firstReference)
        #expect(publicDetails.canonical.map(\.typeIdentifier) == ["public.utf8-plain-text"])
        #expect(publicDetails.canonical.map(\.bytes) == [Data(firstText.utf8)])
        #expect(publicDetails.effective.map(\.typeIdentifier) == ["public.utf8-plain-text"])
        #expect(publicDetails.effective.map(\.bytes) == [Data(firstText.utf8)])
        #expect(publicDetails.revisions.isEmpty)
        #expect(
            publicDetails.occurrence.firstCopiedAt
                == Date(timeIntervalSinceReferenceDate: 2_000)
        )
        #expect(
            publicDetails.occurrence.lastCopiedAt
                == Date(timeIntervalSinceReferenceDate: 2_000)
        )
        #expect(publicDetails.occurrence.count == 1)
        #expect(publicDetails.occurrence.firstSource == nil)
        #expect(publicDetails.occurrence.lastSource == nil)
        #expect(publicDetails.pinnedPosition == nil)

        await #expect(throws: HistoryFailure.notFound(rejectedBundle.domain.candidateID)) {
            try await history.details(for: rejectedBundle.domain.candidateID)
        }

        // §7 item 1 immediate proof: every column of HistoryItemRow and its
        // 1:1 RetainedBytesRow, plus both singleton rows, is identical to the
        // baseline before any successful operation can repair or obscure a
        // partial write. The rejected business ID is absent from both tables.
        let afterFailure = try autoreleasepool {
            try TransactionStoreSnapshot.read(from: url)
        }
        #expect(afterFailure.items == before.items)
        #expect(afterFailure.retainedBytes == before.retainedBytes)
        #expect(afterFailure.positions == before.positions)
        #expect(afterFailure.configs == before.configs)
        #expect(
            !afterFailure.items.map(\.id)
                .contains(rejectedBundle.domain.candidateID.rawValue)
        )
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
    }

    /// §7 item 1 / WS13 seam contract: the injection is ONE-SHOT — it fires
    /// once, disarms itself, and the very next commit succeeds. The
    /// recovered commit lands at position 2 (not 3), independently proving
    /// the failed attempt advanced no durable state.
    @Test func transactionFailureInjectionIsOneShotAndRecoveryCommitsAtNextPosition() async throws {
        let url = WSSupport.tempStoreURL("tx-boundary-one-shot")
        defer { WSSupport.removeStore(url) }

        let authority = try await WSSupport.makeAuthority(storeURL: url)
        let preparation = IngestPreparationActor()

        let firstText = "tx-boundary one-shot first"
        let firstBundle = try await preparation.prepare(
            WSSupport.textCapture(
                firstText,
                observedAt: Date(timeIntervalSinceReferenceDate: 3_000)
            )
        )
        let firstReceipt = try await authority.commitCapture(firstBundle)
        guard case .committed(let firstCommit) = firstReceipt else {
            Issue.record("setup commit did not commit: \(firstReceipt)")
            return
        }
        #expect(firstCommit.position.rawValue == 1)

        await authority.setTransactionFailureInjection(.beforeSingletonUpdate)

        let secondText = "tx-boundary one-shot second"
        let secondBundle = try await preparation.prepare(
            WSSupport.textCapture(
                secondText,
                observedAt: Date(timeIntervalSinceReferenceDate: 3_100)
            )
        )

        // The armed injection fires once …
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await authority.commitCapture(secondBundle)
        }

        // … and disarms, so retrying the SAME bundle succeeds: the failed
        // attempt left nothing durable behind (an `.unchanged` or a throw
        // here would mean residue). Position 2 — exactly one successor past
        // the setup commit — proves the failed attempt minted no position.
        let recoveredReceipt = try await authority.commitCapture(secondBundle)
        guard case .committed(let recoveredCommit) = recoveredReceipt else {
            Issue.record("post-injection commit did not commit: \(recoveredReceipt)")
            return
        }
        #expect(recoveredCommit.position.rawValue == 2)
        guard case .inserted = recoveredCommit.outcome else {
            Issue.record("expected an .inserted outcome, got \(recoveredCommit.outcome)")
            return
        }

        // Both rows and the position-2 singleton are durable together.
        let verification = try WSSupport.makeContainer(storeURL: url)
        let rows = try WSSupport.fetchRows(verification)
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.title)) == [firstText, secondText])

        let position = try WSSupport.fetchPosition(verification)
        #expect(position.rawValue == 2)
    }

    /// The low-disk injection throws a Cocoa out-of-space error from inside
    /// the real transaction closure after row mutation. The production catch
    /// translates it without string matching, while transaction rollback
    /// preserves every durable column and the Change Position (§10, §16).
    @Test func injectedOutOfSpaceTraversesProductionCatchAndRollsBack() async throws {
        let url = WSSupport.tempStoreURL("tx-boundary-out-of-space")
        defer { WSSupport.removeStore(url) }

        let history = try await WSSupport.openHistory(storeURL: url)
        let authority = history.authority
        let preparation = IngestPreparationActor()
        let seed = try await preparation.prepare(
            WSSupport.textCapture(
                "tx-boundary disk seed",
                observedAt: Date(timeIntervalSinceReferenceDate: 4_000)
            )
        )
        _ = try await authority.commitCapture(seed)
        let before = try autoreleasepool {
            try TransactionStoreSnapshot.read(from: url)
        }

        await authority.setTransactionFailureInjection(.insufficientDiskSpace)
        let publicationProbe = await SingleOperationInvalidationPublicationProbe.begin(
            on: authority
        )
        let rejected = try await preparation.prepare(
            WSSupport.textCapture(
                "tx-boundary disk rejected",
                observedAt: Date(timeIntervalSinceReferenceDate: 4_100)
            )
        )

        await #expect(
            throws: HistoryFailure.temporarilyUnavailable(.insufficientDiskSpace)
        ) {
            try await authority.commitCapture(rejected)
        }
        let publications = try await publicationProbe.finish(on: authority)
        #expect(publications.count == 0)

        let after = try autoreleasepool {
            try TransactionStoreSnapshot.read(from: url)
        }
        #expect(after == before)

        let readableOldState = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 10
        ))
        #expect(readableOldState.position.rawValue == 1)
        #expect(readableOldState.rows.map(\.title) == ["tx-boundary disk seed"])
    }
}

/// Shared value-only rollback oracle for transaction-boundary tests. Raw blobs
/// are copied directly so equality covers every persisted column without a
/// hash or a codec-derived summary.
struct TransactionItemSnapshot: Equatable, Sendable {
    let id: UUID
    let contentVersionRaw: UInt64
    let canonicalBlob: Data
    let revisionStateBlob: Data
    let canonicalSignatureBlob: Data
    let projectionSchemaVersion: UInt16
    let title: String
    let searchBody: String
    let effectiveTypeIdentifiersBlob: Data
    let firstCopiedAt: Date
    let lastCopiedAt: Date
    let copyCount: UInt64
    let firstSource: String?
    let lastSource: String?
    let pinOrdinal: Int?

    init(_ row: HistoryItemRow) {
        id = row.id
        contentVersionRaw = row.contentVersionRaw
        canonicalBlob = row.canonicalBlob
        revisionStateBlob = row.revisionStateBlob
        canonicalSignatureBlob = row.canonicalSignatureBlob
        projectionSchemaVersion = row.projectionSchemaVersion
        title = row.title
        searchBody = row.searchBody
        effectiveTypeIdentifiersBlob = row.effectiveTypeIdentifiersBlob
        firstCopiedAt = row.firstCopiedAt
        lastCopiedAt = row.lastCopiedAt
        copyCount = row.copyCount
        firstSource = row.firstSource
        lastSource = row.lastSource
        pinOrdinal = row.pinOrdinal
    }
}

struct TransactionRetainedBytesSnapshot: Equatable, Sendable {
    let itemID: UUID
    let canonicalBytes: Int
    let revisionCount: Int
    let revisionBytes: Int
    let bytesSchemaVersion: UInt16

    init(_ row: RetainedBytesRow) {
        itemID = row.itemID
        canonicalBytes = row.canonicalBytes
        revisionCount = row.revisionCount
        revisionBytes = row.revisionBytes
        bytesSchemaVersion = row.bytesSchemaVersion
    }

    init(
        itemID: UUID,
        canonicalBytes: Int,
        revisionCount: Int,
        revisionBytes: Int,
        bytesSchemaVersion: UInt16
    ) {
        self.itemID = itemID
        self.canonicalBytes = canonicalBytes
        self.revisionCount = revisionCount
        self.revisionBytes = revisionBytes
        self.bytesSchemaVersion = bytesSchemaVersion
    }
}

struct TransactionPositionSnapshot: Equatable, Sendable {
    let key: String
    let rawValue: UInt64
    let maximumUnpinnedItems: Int

    init(_ row: LastChangePositionRow) {
        key = row.key
        rawValue = row.rawValue
        maximumUnpinnedItems = row.maximumUnpinnedItems
    }

    init(key: String, rawValue: UInt64, maximumUnpinnedItems: Int) {
        self.key = key
        self.rawValue = rawValue
        self.maximumUnpinnedItems = maximumUnpinnedItems
    }
}

struct TransactionConfigSnapshot: Equatable, Sendable {
    let key: String
    let agePolicyEnabled: Bool
    let ageMaxSeconds: Double
    let storagePolicyEnabled: Bool
    let storageMaxBytes: Int
    let revisionPolicyEnabled: Bool
    let revisionMaxCount: Int?
    let revisionMaxBytes: Int?
    let configSchemaVersion: UInt16

    init(_ row: RetentionExpansionConfigRow) {
        key = row.key
        agePolicyEnabled = row.agePolicyEnabled
        ageMaxSeconds = row.ageMaxSeconds
        storagePolicyEnabled = row.storagePolicyEnabled
        storageMaxBytes = row.storageMaxBytes
        revisionPolicyEnabled = row.revisionPolicyEnabled
        revisionMaxCount = row.revisionMaxCount
        revisionMaxBytes = row.revisionMaxBytes
        configSchemaVersion = row.configSchemaVersion
    }

    init(
        key: String,
        agePolicyEnabled: Bool,
        ageMaxSeconds: Double,
        storagePolicyEnabled: Bool,
        storageMaxBytes: Int,
        revisionPolicyEnabled: Bool,
        revisionMaxCount: Int?,
        revisionMaxBytes: Int?,
        configSchemaVersion: UInt16
    ) {
        self.key = key
        self.agePolicyEnabled = agePolicyEnabled
        self.ageMaxSeconds = ageMaxSeconds
        self.storagePolicyEnabled = storagePolicyEnabled
        self.storageMaxBytes = storageMaxBytes
        self.revisionPolicyEnabled = revisionPolicyEnabled
        self.revisionMaxCount = revisionMaxCount
        self.revisionMaxBytes = revisionMaxBytes
        self.configSchemaVersion = configSchemaVersion
    }
}

struct TransactionStoreSnapshot: Equatable, Sendable {
    let items: [TransactionItemSnapshot]
    let retainedBytes: [TransactionRetainedBytesSnapshot]
    let positions: [TransactionPositionSnapshot]
    let configs: [TransactionConfigSnapshot]

    static func read(from storeURL: URL) throws -> TransactionStoreSnapshot {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let itemRows = try context.fetch(FetchDescriptor<HistoryItemRow>())
        let bytesRows = try context.fetch(FetchDescriptor<RetainedBytesRow>())
        let positionRows = try context.fetch(FetchDescriptor<LastChangePositionRow>())
        let configRows = try context.fetch(FetchDescriptor<RetentionExpansionConfigRow>())
        return TransactionStoreSnapshot(
            items: itemRows.map(TransactionItemSnapshot.init).sorted {
                HistoryItemID(rawValue: $0.id) < HistoryItemID(rawValue: $1.id)
            },
            retainedBytes: bytesRows.map(TransactionRetainedBytesSnapshot.init).sorted {
                HistoryItemID(rawValue: $0.itemID) < HistoryItemID(rawValue: $1.itemID)
            },
            positions: positionRows.map(TransactionPositionSnapshot.init).sorted {
                $0.key < $1.key
            },
            configs: configRows.map(TransactionConfigSnapshot.init).sorted {
                $0.key < $1.key
            }
        )
    }
}
