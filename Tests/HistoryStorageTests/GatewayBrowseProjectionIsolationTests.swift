/// X.7 purpose-specific browse projection isolation. App Intents consumes
/// revision-count facts only for rows its bounded page returns, while Local
/// Automation keeps the unchanged V1 page and never consumes that projection.
/// Owning spec: `V2-05` §5.2/§7.1/§9 X-PERF-3.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("Gateway browse projection isolation (X.7)")
struct GatewayBrowseProjectionIsolationTests {
    private static let epoch = Date(
        timeIntervalSinceReferenceDate: 944_000_000
    )
    private static let localConnection = ExternalConnectionID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-000000004410"
    )!)

    @Test("App Intent pages ignore malformed and out-of-range non-result count facts")
    func appIntentPagesIgnoreUnrelatedRevisionCountDamage() async throws {
        let history = try await SQLiteHistory.open(configuration:
            HistoryConfiguration(persistence: .temporary)
        )
        let noninteger = try await Self.capture(
            "gateway-projection-unrelated-noninteger",
            at: Self.epoch,
            in: history
        )
        let malformed = try await Self.capture(
            "gateway-projection-unrelated-malformed",
            at: Self.epoch.addingTimeInterval(1),
            in: history
        )
        let matched = try await Self.capture(
            "gateway-projection-match-canonical",
            at: Self.epoch.addingTimeInterval(2),
            in: history
        )
        let revisedTitle = "gateway-projection-match-revised"
        let revised = try await Self.revise(
            matched,
            to: revisedTitle,
            in: history
        )
        let connection = try #require(try await history.connections().first)
        try await history.grantCapability(.browse, to: connection.id)
        try await Self.setNonintegerRevisionCount(
            for: noninteger.id,
            in: history.authority
        )
        try await Self.setRevisionCount(
            HistoryLimits.standard.maximumRevisionsPerItem + 1,
            for: malformed.id,
            in: history.authority
        )

        let facade = history.makeAppIntentsHistoryFacade()
        guard case .page(let recent) = try await facade.read(
            .recent(limit: 1)
        ) else {
            Issue.record("expected one external recent page")
            return
        }
        let recentRow = try #require(recent.rows.first)
        #expect(recent.rows.count == 1)
        #expect(recentRow.row.item == revised)
        #expect(recentRow.row.title == revisedTitle)
        #expect(recentRow.revisionCount == 1)

        let result = try await facade.read(
            .search(text: revisedTitle, mode: .exact, limit: 1)
        )

        guard case .page(let page) = result else {
            Issue.record("expected one external search page")
            return
        }
        let row = try #require(page.rows.first)
        #expect(page.rows.count == 1)
        #expect(row.row.item == revised)
        #expect(row.row.title == revisedTitle)
        #expect(row.revisionCount == 1)
    }

    @Test("selected noninteger count fails only after its failed audit commits")
    func appIntentSearchAuditsSelectedNonintegerRevisionCount() async throws {
        let history = try await SQLiteHistory.open(configuration:
            HistoryConfiguration(persistence: .temporary)
        )
        let privateQuery = "gateway-projection-selected-noninteger"
        let matched = try await Self.capture(
            privateQuery,
            at: Self.epoch,
            in: history
        )
        let connection = try #require(try await history.connections().first)
        try await history.grantCapability(.browse, to: connection.id)
        let authority = history.authority
        let before = try await GatewayStoreSnapshot.read(from: authority)
        try await Self.setNonintegerRevisionCount(for: matched.id, in: authority)

        await #expect(throws:
            ExternalFailure.persistence(.invariantViolation)
        ) {
            _ = try await history.makeAppIntentsHistoryFacade().read(
                .search(text: privateQuery, mode: .exact, limit: 1)
            )
        }

        try await Self.expectFailedSearchAudit(
            in: authority,
            appendedAfter: before.operations.count,
            connection: connection.id,
            privateQuery: privateQuery
        )
    }

    @Test("App Intent search still fails closed for a returned corrupt count")
    func appIntentSearchRejectsSelectedCorruptRevisionCount() async throws {
        let history = try await SQLiteHistory.open(configuration:
            HistoryConfiguration(persistence: .temporary)
        )
        let matched = try await Self.capture(
            "gateway-projection-selected-corrupt",
            at: Self.epoch,
            in: history
        )
        let privateQuery = "selected-corrupt"
        let connection = try #require(try await history.connections().first)
        try await history.grantCapability(.browse, to: connection.id)
        let authority = history.authority
        let before = try await GatewayStoreSnapshot.read(from: authority)
        try await Self.setRevisionCount(
            HistoryLimits.standard.maximumRevisionsPerItem + 1,
            for: matched.id,
            in: authority
        )

        await #expect(throws:
            ExternalFailure.persistence(.invariantViolation)
        ) {
            _ = try await history.makeAppIntentsHistoryFacade().read(
                .search(
                    text: privateQuery,
                    mode: .exact,
                    limit: 1
                )
            )
        }
        try await Self.expectFailedSearchAudit(
            in: authority,
            appendedAfter: before.operations.count,
            connection: connection.id,
            privateQuery: privateQuery
        )
    }

    @Test("Local Automation recent and search do not consume revision counts")
    func localAutomationKeepsV1Projection() async throws {
        let history = try await SQLiteHistory.open(configuration:
            HistoryConfiguration(persistence: .temporary)
        )
        let item = try await Self.capture(
            "gateway-local-projection-isolation",
            at: Self.epoch,
            in: history
        )
        try await history.authority.publishVerifiedLocalAutomationEnrollment(
            Self.localConnection,
            displayName: "Projection isolation fixture"
        )
        try await history.grantCapability(
            .browsePreview,
            to: Self.localConnection
        )
        try await Self.setRevisionCount(
            HistoryLimits.standard.maximumRevisionsPerItem + 1,
            for: item.id,
            in: history.authority
        )

        let recent = try await history.authority
            .performLocalAutomationBrowsePreview(
                .recent(limit: 1),
                connection: Self.localConnection,
                requestedAt: Self.epoch,
                searchWorker: history.searchWorker
            )
        let search = try await history.authority
            .performLocalAutomationBrowsePreview(
                .search(
                    text: "projection-isolation",
                    mode: .exact,
                    limit: 1
                ),
                connection: Self.localConnection,
                requestedAt: Self.epoch,
                searchWorker: history.searchWorker
            )

        #expect(recent.rows.map(\.item.id) == [item.id])
        #expect(search.rows.map(\.item.id) == [item.id])
    }

    @Test("the current item schema rejects an absent revision count")
    func revisionCountCannotBeNull() async throws {
        let history = try await SQLiteHistory.open(configuration:
            HistoryConfiguration(persistence: .temporary)
        )
        let item = try await Self.capture("required-revision-count", at: Self.epoch, in: history)
        try await history.authority.withTestDatabase { authority in
            let before = try GatewayHistoryTestSnapshot.read(in: authority)
            do {
                try authority.database.writeTransaction {
                    try authority.database.execute(
                        "UPDATE history_items SET revisionCount = NULL WHERE id = ?",
                        bindings: [.text(item.id.rawValue.uuidString)]
                    )
                }
                Issue.record("revisionCount unexpectedly accepted NULL")
            } catch let failure as SQLiteFailure {
                #expect(failure.isConstraint)
            }
            #expect(try GatewayHistoryTestSnapshot.read(in: authority) == before)
        }
    }

    private static func capture(
        _ text: String,
        at observedAt: Date,
        in history: SQLiteHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text,
            observedAt: observedAt
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let reference) = commit.outcome else {
            Issue.record("expected fixture capture to insert")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return reference
    }

    private static func revise(
        _ reference: HistoryItemReference,
        to text: String,
        in history: SQLiteHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: reference.id,
            expected: reference.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: "public.utf8-plain-text",
                    action: .replace(bytes: Data(text.utf8))
                ),
            ]))
        )))
        guard case .committed(let commit) = receipt,
              case .revised(let revised) = commit.outcome else {
            Issue.record("expected fixture revision to commit")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return revised
    }

    private static func setRevisionCount(
        _ count: Int, for item: HistoryItemID, in authority: HistoryAuthority
    ) async throws {
        try await authority.withTestDatabase { authority in
            try authority.database.writeTransaction {
                try authority.database.execute(
                    "UPDATE history_items SET revisionCount = ? WHERE id = ?",
                    bindings: [.integer(Int64(count)), .text(item.rawValue.uuidString)]
                )
                #expect(try authority.database.changedRowCount == 1)
            }
        }
    }

    private static func setNonintegerRevisionCount(
        for item: HistoryItemID, in authority: HistoryAuthority
    ) async throws {
        // Revision counts now live on the item and cannot be absent. A wrong
        // SQLite storage class exercises an unreadable selected count without
        // reconstructing the removed byte-accounting table.
        try await authority.withTestDatabase { authority in
            try authority.database.writeTransaction {
                try authority.database.execute(
                    "UPDATE history_items SET revisionCount = ? WHERE id = ?",
                    bindings: [.text("missing"), .text(item.rawValue.uuidString)]
                )
                #expect(try authority.database.changedRowCount == 1)
            }
        }
    }

    private static func expectFailedSearchAudit(
        in authority: HistoryAuthority,
        appendedAfter previousCount: Int,
        connection: ExternalConnectionID,
        privateQuery: String
    ) async throws {
        let after = try await GatewayStoreSnapshot.read(from: authority)
        let appended = Array(after.operations.dropFirst(previousCount))
        #expect(appended.count == 1)
        let audit = try #require(appended.first)
        #expect(audit.connectionIDRaw == connection.rawValue)
        #expect(audit.capabilityRaw == ExternalCapability.browse.rawValue)
        #expect(audit.operationKindRaw
            == ExternalOperationKind.readSearch.rawValue)
        #expect(audit.outcomeRaw == ExternalOutcome.failed.rawValue)
        #expect(audit.failureKindRaw
            == ExternalFailureKindRaw.persistence.rawValue)
        #expect(audit.denialReasonRaw == nil)
        #expect(audit.changePositionRaw == nil)
        #expect(audit.payloadBlob.range(of: Data(privateQuery.utf8)) == nil)
    }
}
