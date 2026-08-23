/// D1 stable-identity retirement proof (`02` §14): deleting an item never
/// redirects or reuses its identity, even when byte-identical content is
/// captured again later. The test observes only the public History boundary;
/// it uses no SwiftData row oracle, substitute writer, or fingerprint fact.
import Foundation
import HistoryCore
import HistoryStorage
import Testing

@Suite("Stable identity retirement (D1)")
struct StableIdentityRetirementTests {
    private static let literalA = "stable-identity-retirement-literal-A"
    private static let firstObservedAt = Date(
        timeIntervalSinceReferenceDate: 916_000_000
    )
    private static let secondObservedAt = Date(
        timeIntervalSinceReferenceDate: 916_000_100
    )

    @Test("byte-identical recapture after removal mints a fresh item identity")
    func byteIdenticalRecaptureAfterRemovalUsesFreshIdentity() async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )

        let firstReceipt = try await history.perform(.capture(
            Self.capture(observedAt: Self.firstObservedAt)
        ))
        guard case .committed(let firstCommit) = firstReceipt,
              case .inserted(let firstReference) = firstCommit.outcome else {
            Issue.record(
                "expected first capture to insert, got \(firstReceipt)"
            )
            return
        }
        #expect(firstCommit.position.rawValue == 1)
        #expect(firstReference.contentVersion.rawValue == 1)

        let removeReceipt = try await history.perform(
            .remove(firstReference.id)
        )
        guard case .committed(let removeCommit) = removeReceipt,
              case .removed(count: 1) = removeCommit.outcome else {
            Issue.record("expected one retirement, got \(removeReceipt)")
            return
        }
        #expect(removeCommit.position.rawValue == 2)

        let emptyPage = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 10
        ))
        #expect(emptyPage.position == removeCommit.position)
        #expect(emptyPage.rows.isEmpty)
        #expect(emptyPage.next == nil)

        let secondReceipt = try await history.perform(.capture(
            Self.capture(observedAt: Self.secondObservedAt)
        ))
        guard case .committed(let secondCommit) = secondReceipt,
              case .inserted(let secondReference) = secondCommit.outcome else {
            Issue.record(
                "expected recapture to insert a new item, got \(secondReceipt)"
            )
            return
        }

        // D1: byte equality can coalesce only with a retained winner. Once
        // the first item is retired, the same bytes create a distinct item;
        // the old identity is neither reused nor redirected.
        #expect(secondReference.id != firstReference.id)
        #expect(secondReference.contentVersion.rawValue == 1)
        #expect(secondCommit.position.rawValue == 3)

        let currentPage = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 10
        ))
        #expect(currentPage.position == secondCommit.position)
        #expect(currentPage.rows.map(\.item) == [secondReference])
        #expect(currentPage.rows.map(\.title) == [Self.literalA])
        #expect(currentPage.rows.map(\.copyCount) == [1])
        #expect(currentPage.rows.map(\.lastCopiedAt) == [Self.secondObservedAt])
        #expect(currentPage.next == nil)

        await #expect(throws: HistoryFailure.notFound(firstReference.id)) {
            _ = try await history.details(for: firstReference.id)
        }
    }

    private static func capture(observedAt: Date) -> ClipboardCapture {
        ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data(literalA.utf8)
            )],
            origin: CopyOriginObservation(
                sourceApplication: "StableIdentityRetirementTests",
                lineageHint: nil
            ),
            observedAt: observedAt
        )
    }
}
