/// Card 2B-2 — Storage-generated History Item ID collision recovery.
///
/// The behavior seam is the real `SwiftDataHistory` facade: a package-only
/// deterministic ID source supplies collisions, while capture, browse, and
/// details all cross the caller-visible History API. The existing Debug-only
/// storage lifecycle probe proves retry happens before the transaction; the
/// Authority invalidation stream proves failed candidates are never published.
/// Owning review: `04-tdd-remediation-playbook.md` Card 2B-2; capture owner:
/// docs/05-authority-kernel.md §6.1/§9–§11.
import Foundation
import HistoryCore
import Synchronization
import Testing
@testable import HistoryStorage

@Suite("Capture item-ID collision recovery (Card 2B-2)")
struct CaptureItemIDCollisionRecoveryTests {
    private static let collidingID = HistoryItemID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000002201"
    )!)
    private static let recoveredID = HistoryItemID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000002202"
    )!)

    private final class CandidateIDSource: Sendable {
        private struct State: Sendable {
            var values: [HistoryItemID]
            var calls = 0
        }

        private let state: Mutex<State>

        init(_ values: [HistoryItemID]) {
            precondition(!values.isEmpty)
            state = Mutex(State(values: values))
        }

        func next() -> HistoryItemID {
            state.withLock { state in
                precondition(!state.values.isEmpty)
                let index = min(state.calls, state.values.count - 1)
                let value = state.values[index]
                state.calls += 1
                return value
            }
        }

        var callCount: Int {
            state.withLock { $0.calls }
        }
    }

#if DEBUG
    private final class CaptureTransactionProbe: Sendable {
        private let phases = Mutex<[StorageLifecycleDebugPhase]>([])

        func record(_ phase: StorageLifecycleDebugPhase) {
            phases.withLock { $0.append(phase) }
        }

        var transactionBegins: Int {
            phases.withLock { phases in
                phases.filter { $0 == .captureTransactionBegin }.count
            }
        }

        var transactionCompletions: Int {
            phases.withLock { phases in
                phases.filter { $0 == .captureTransactionComplete }.count
            }
        }
    }
#endif

    @Test("one occupied candidate retries to a fresh ID and commits once")
    func oneCollisionRetriesThenCommitsOnce() async throws {
        let source = CandidateIDSource([
            Self.collidingID,
            Self.collidingID,
            Self.recoveredID,
        ])
        let history = try await Self.openHistory(candidateIDSource: { source.next() })

        let seedReceipt = try await history.perform(.capture(Self.capture(
            "card-2b-2 seed",
            observedAt: 20_001
        )))
        guard case .committed(let seedCommit) = seedReceipt,
              case .inserted(let seedReference) = seedCommit.outcome
        else {
            Issue.record("seed capture did not insert: \(seedReceipt)")
            return
        }
        #expect(seedReference.id == Self.collidingID)
        #expect(seedCommit.position.rawValue == 1)

        let registration = await history.authority.registerInvalidationSubscriber()
#if DEBUG
        let transactionProbe = CaptureTransactionProbe()
        await history.authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: true) { event in
                transactionProbe.record(event.phase)
            }
        )
#endif

        let recoveredReceipt = try await history.perform(.capture(Self.capture(
            "card-2b-2 recovered",
            observedAt: 20_002
        )))
        guard case .committed(let recoveredCommit) = recoveredReceipt,
              case .inserted(let recoveredReference) = recoveredCommit.outcome
        else {
            Issue.record("recovered capture did not insert: \(recoveredReceipt)")
            return
        }
        #expect(recoveredReference.id == Self.recoveredID)
        #expect(recoveredCommit.position.rawValue == 2)
        #expect(source.callCount == 3)

#if DEBUG
        #expect(transactionProbe.transactionBegins == 1)
        #expect(transactionProbe.transactionCompletions == 1)
#endif

        await history.authority.unregisterInvalidationSubscriber(
            registration.subscription
        )
        var invalidations: [HistoryInvalidation] = []
        for try await invalidation in registration.stream {
            invalidations.append(invalidation)
        }
        #expect(invalidations.count == 1)
        #expect(invalidations.first?.latestPosition.rawValue == 2)

        let page = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 10
        ))
        #expect(page.position.rawValue == 2)
        #expect(page.rows.map(\.item.id) == [Self.recoveredID, Self.collidingID])

        let seedDetails = try await history.details(for: Self.collidingID)
        #expect(seedDetails.item == seedReference)
        #expect(seedDetails.effective.map(\.bytes) == [Data("card-2b-2 seed".utf8)])
        #expect(seedDetails.occurrence.count == 1)
        #expect(
            seedDetails.occurrence.lastCopiedAt
                == Date(timeIntervalSinceReferenceDate: 20_001)
        )
        let recoveredDetails = try await history.details(for: Self.recoveredID)
        #expect(recoveredDetails.item == recoveredReference)
        #expect(
            recoveredDetails.effective.map(\.bytes)
                == [Data("card-2b-2 recovered".utf8)]
        )
    }

    @Test("an always-occupied source exhausts the fixed bound without a write or publish")
    func exhaustedCollisionsFailWithoutCommitOrPublish() async throws {
        let source = CandidateIDSource([Self.collidingID])
        let history = try await Self.openHistory(candidateIDSource: { source.next() })

        let seedReceipt = try await history.perform(.capture(Self.capture(
            "card-2b-2 durable seed",
            observedAt: 20_101
        )))
        guard case .committed(let seedCommit) = seedReceipt,
              case .inserted(let seedReference) = seedCommit.outcome
        else {
            Issue.record("seed capture did not insert: \(seedReceipt)")
            return
        }
        #expect(seedCommit.position.rawValue == 1)

        let registration = await history.authority.registerInvalidationSubscriber()
#if DEBUG
        let transactionProbe = CaptureTransactionProbe()
        await history.authority.setStorageLifecycleDebugProbe(
            StorageLifecycleDebugProbe(isEnabled: true) { event in
                transactionProbe.record(event.phase)
            }
        )
#endif

        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try await history.perform(.capture(Self.capture(
                "card-2b-2 rejected",
                observedAt: 20_102
            )))
        }
        #expect(
            source.callCount
                == SwiftDataHistory.captureCandidateIDAttemptLimit + 1
        )

#if DEBUG
        #expect(transactionProbe.transactionBegins == 0)
        #expect(transactionProbe.transactionCompletions == 0)
#endif

        await history.authority.unregisterInvalidationSubscriber(
            registration.subscription
        )
        var invalidations: [HistoryInvalidation] = []
        for try await invalidation in registration.stream {
            invalidations.append(invalidation)
        }
        #expect(invalidations.isEmpty)

        let page = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 10
        ))
        #expect(page.position.rawValue == 1)
        #expect(page.rows.map(\.item.id) == [Self.collidingID])
        let seedDetails = try await history.details(for: Self.collidingID)
        #expect(seedDetails.item == seedReference)
        #expect(seedDetails.occurrence.count == 1)
        #expect(
            seedDetails.occurrence.lastCopiedAt
                == Date(timeIntervalSinceReferenceDate: 20_101)
        )
        #expect(
            seedDetails.effective.map(\.bytes)
                == [Data("card-2b-2 durable seed".utf8)]
        )
    }

    private static func openHistory(
        candidateIDSource: @escaping @Sendable () -> HistoryItemID
    ) async throws -> SwiftDataHistory {
        try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory),
            makeCandidateID: candidateIDSource
        )
    }

    private static func capture(
        _ text: String,
        observedAt: TimeInterval
    ) -> ClipboardCapture {
        ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data(text.utf8)
            )],
            origin: CopyOriginObservation(
                sourceApplication: "card-2b-2",
                lineageHint: nil
            ),
            observedAt: Date(timeIntervalSinceReferenceDate: observedAt)
        )
    }
}
