/// Transaction boundary proof (docs/06-cross-cutting.md §7 item 1): closure
/// success durably commits item mutations and the singleton position once,
/// with no extra `save()`; closure failure commits neither.
/// Owning spec: docs/05-authority-kernel.md §10 (the only durable History
/// Commit primitive is `ModelContext.transaction`; "closure success is the
/// save boundary", "closure failure commits nothing"), §16 (every closure
/// failure maps to `.persistence(.transaction)`); WS13 durable half:
/// docs/06-cross-cutting.md §8.
///
/// Storage-side proof, not a public-facade path: the one-shot
/// transaction-failure seam (`setTransactionFailureInjection` /
/// `InjectedTransactionFailure.beforeSingletonUpdate`) is an @testable-only
/// knob on `HistoryAuthority`, so these tests drive a direct Authority plus
/// the real `IngestPreparationActor` (see `WSSupport.makeAuthority`). All
/// durable-state assertions run on an INDEPENDENT fresh `ModelContainer`
/// over the same on-disk store: the Authority's operation-local contexts
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

        let authority = try await WSSupport.makeAuthority(storeURL: url)
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

        // §7 item 1 proof: the fresh independent container sees EXACTLY the
        // pre-attempt state — one row (the first capture's, unchanged) and
        // the singleton still at position 1. The rejected row never became
        // durable and the position never advanced (§10: "Closure failure
        // commits nothing").
        let verification = try WSSupport.makeContainer(storeURL: url)
        let rows = try WSSupport.fetchRows(verification)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.id == firstReference.id.rawValue)
        #expect(row.title == firstText)
        #expect(row.copyCount == 1)

        let position = try WSSupport.fetchPosition(verification)
        #expect(position.rawValue == 1)
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
}
