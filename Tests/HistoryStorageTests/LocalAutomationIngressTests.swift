import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("Local Automation ingress", .serialized)
struct LocalAutomationIngressTests {
    private struct Fixture: Sendable {
        let history: SwiftDataHistory
        let ingress: LocalAutomationIngress
        let credentials: [LocalAutomationCredential]
        let credentialStore: CredentialStore
    }

    @Test func effectiveReadsReturnOnlyCurrentBytesAndRequireTheirOwnGrant() async throws {
        let fixture = try await makeFixture()
        let credential = fixture.credentials[0]
        let row = try #require(try await page(fixture).rows.first)
        let item = try #require(try await fixture.history.browse(
            HistoryBrowseRequest(kind: .recent, limit: 10)
        ).rows.first?.item)
        let currentBytes = Data([0x42, 0x00, 0xFF])
        _ = try await fixture.history.perform(.revise(RevisionRequest(
            itemID: item.id, expected: item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(
                    typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: currentBytes)
                ),
            ]))
        )))
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .readEffectiveContent, connectionID: credential.connection
        )) {
            _ = try await fixture.ingress.execute(
                .detailsEffective(locator: row.locator), presenting: credential.exactBytes
            )
        }
        try await fixture.history.grantCapability(.readEffectiveContent, to: credential.connection)
        // A retained locator is sufficient with this independent grant;
        // content read never implies browse, nor requires it to remain granted.
        try await fixture.history.revokeCapability(.browsePreview, of: credential.connection)
        for request in [
            LocalAutomationRequest.detailsEffective(locator: row.locator),
            .pasteEffective(locator: row.locator),
        ] {
            guard case .effective(let content) = try await fixture.ingress.execute(
                request, presenting: credential.exactBytes
            ) else {
                Issue.record("Expected Effective-only content")
                return
            }
            #expect(content.locator == row.locator)
            #expect(content.contentVersion == 2)
            #expect(content.representations.count == 1)
            #expect(content.representations[0].bytes == currentBytes)
        }
        // Fresh stores retain audit sequences starting at 1; `since` is inclusive.
        let audit = try await fixture.history.auditLog(since: 1)
        let reads = audit.filter { $0.operationKind == .readEffectiveContent }
        #expect(reads.count == 3)
        #expect(reads.map(\.outcome) == [.denied, .succeeded, .succeeded])
        #expect(reads.allSatisfy { $0.capability == .readEffectiveContent })
    }

    @Test func organizeCannotDeleteAndSuccessfulRemovalPurgesBeforeReply() async throws {
        let removal = IngressRemovalRecorder()
        let fixture = try await makeFixture(onCommittedRemoval: { await removal.record($0) })
        let credential = fixture.credentials[0]
        let row = try #require(try await page(fixture).rows.first)
        try await fixture.history.grantCapability(.organize, to: credential.connection)
        for request in [LocalAutomationRequest.pin(locator: row.locator), .unpin(locator: row.locator)] {
            guard case .changed = try await fixture.ingress.execute(
                request, presenting: credential.exactBytes
            ) else {
                Issue.record("Expected one organizing commit")
                return
            }
        }
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .deleteItem, connectionID: credential.connection
        )) {
            _ = try await fixture.ingress.execute(.delete(locator: row.locator), presenting: credential.exactBytes)
        }
        #expect(try await page(fixture).rows.count == 1)
        try await fixture.history.grantCapability(.deleteItem, to: credential.connection)
        guard case .changed = try await fixture.ingress.execute(
            .delete(locator: row.locator), presenting: credential.exactBytes
        ) else {
            Issue.record("Expected one delete commit")
            return
        }
        #expect(try await page(fixture).rows.isEmpty)
        #expect(await removal.count == 1)
        let audit = try await fixture.history.auditLog(since: 1)
        let writes = audit.filter { [.managePin, .manageUnpin, .manageRemove].contains($0.operationKind) }
        #expect(writes.map(\.capability) == [.organize, .organize, .deleteItem, .deleteItem])
        #expect(writes.map(\.outcome) == [.succeeded, .succeeded, .denied, .succeeded])
        #expect(writes.last?.changePosition != nil)
    }

    @Test func pagingTokensAreOpaqueAndBoundToConnectionQueryAndIngressLifetime() async throws {
        let fixture = try await makeFixture(itemCount: 3, connectionCount: 2)
        let first = try await page(fixture, limit: 1)
        let cursor = try #require(first.nextCursor)
        let firstRow = try #require(first.rows.first)
        let second = try await page(fixture, limit: 1, cursor: cursor)
        #expect(second.rows.count == 1)
        #expect(second.rows[0].locator != firstRow.locator)
        #expect(try await page(fixture, limit: 1).rows.first?.locator == firstRow.locator)
        let thirdCursor = try #require(second.nextCursor)
        let third = try await page(fixture, limit: 1, cursor: thirdCursor)
        #expect(third.rows.count == 1)
        #expect(third.nextCursor == nil)
        guard case .page(let searchPage) = try await fixture.ingress.execute(
            .search(text: "sentinel", mode: .exact, limit: 1, cursor: nil),
            presenting: fixture.credentials[0].exactBytes
        ) else {
            Issue.record("Expected the first authenticated search page")
            return
        }
        let searchCursor = try #require(searchPage.nextCursor)
        guard case .page(let searchNext) = try await fixture.ingress.execute(
            .search(text: "sentinel", mode: .exact, limit: 1, cursor: searchCursor),
            presenting: fixture.credentials[0].exactBytes
        ) else {
            Issue.record("Expected two authenticated search pages")
            return
        }
        #expect(searchNext.rows.count == 1)
        #expect(searchNext.rows[0].locator != searchPage.rows[0].locator)
        await #expect(throws: LocalAutomationIngressFailure.cursorExpired) {
            _ = try await page(fixture, limit: 2, cursor: cursor)
        }
        await #expect(throws: LocalAutomationIngressFailure.cursorExpired) {
            _ = try await fixture.ingress.execute(
                .search(text: "sentinel", mode: .exact, limit: 1, cursor: cursor),
                presenting: fixture.credentials[0].exactBytes
            )
        }
        await #expect(throws: LocalAutomationIngressFailure.locatorInvalidated) {
            _ = try await fixture.ingress.execute(
                .pin(locator: firstRow.locator), presenting: fixture.credentials[1].exactBytes
            )
        }
        await #expect(throws: LocalAutomationIngressFailure.cursorExpired) {
            _ = try await fixture.ingress.execute(
                .recent(limit: 1, cursor: cursor), presenting: fixture.credentials[1].exactBytes
            )
        }
        let restarted = LocalAutomationIngress(
            authority: fixture.history.authority, gateway: fixture.history.externalGateway,
            credentialStore: fixture.credentialStore
        )
        await #expect(throws: LocalAutomationIngressFailure.cursorExpired) {
            _ = try await restarted.execute(
                .recent(limit: 1, cursor: cursor), presenting: fixture.credentials[0].exactBytes
            )
        }
        await #expect(throws: LocalAutomationIngressFailure.locatorInvalidated) {
            _ = try await restarted.execute(
                .pasteEffective(locator: firstRow.locator), presenting: fixture.credentials[0].exactBytes
            )
        }
        // The private snapshot cursor must also expire after a History write.
        _ = try await fixture.history.perform(.capture(WSSupport.textCapture(
            "new item", observedAt: Date(timeIntervalSinceReferenceDate: 960_001_000)
        )))
        await #expect(throws: LocalAutomationIngressFailure.cursorExpired) {
            _ = try await page(fixture, limit: 1, cursor: cursor)
        }
    }

    @Test func wrongCredentialAndUnknownLocatorPublishNoContent() async throws {
        let fixture = try await makeFixture()
        var wrong = fixture.credentials[0].exactBytes
        wrong[47] ^= 1
        await #expect(throws: LocalAutomationIngressFailure.authenticationFailed) {
            _ = try await fixture.ingress.execute(.recent(limit: 1, cursor: nil), presenting: wrong)
        }
        await #expect(throws: LocalAutomationIngressFailure.locatorInvalidated) {
            _ = try await fixture.ingress.execute(
                .pasteEffective(locator: "i1_forged"), presenting: fixture.credentials[0].exactBytes
            )
        }
    }

    @Test func cursorStorageEvictsOnlyItsOldestTokenAtTheFixedBound() async throws {
        let fixture = try await makeFixture(itemCount: 2)
        let first = try #require(try await page(fixture, limit: 1).nextCursor)
        var latest = first
        for _ in 0..<64 {
            latest = try #require(try await page(fixture, limit: 1).nextCursor)
        }
        await #expect(throws: LocalAutomationIngressFailure.cursorExpired) {
            _ = try await page(fixture, limit: 1, cursor: first)
        }
        #expect(try await page(fixture, limit: 1, cursor: latest).rows.count == 1)
    }

    @Test func unavailableServerCustodyIsRetryableRatherThanAuthenticationFailure() async throws {
        let fixture = try await makeFixture()
        let ingress = LocalAutomationIngress(
            authority: fixture.history.authority, gateway: fixture.history.externalGateway,
            credentialStore: CredentialStore(operations: IngressMemoryCredentialOperations(
                values: [:], unavailable: true
            ))
        )
        await #expect(throws: ExternalFailure.temporarilyUnavailable(.storeLocked)) {
            _ = try await ingress.execute(
                .recent(limit: 1, cursor: nil), presenting: fixture.credentials[0].exactBytes
            )
        }
    }

#if DEBUG
    @Test func revocationDuringSearchPreventsItsResultPublication() async throws {
        let fixture = try await makeFixture()
        let credential = fixture.credentials[0]
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .browsePreview, connectionID: credential.connection
        )) {
            try await ExternalReadPublicationDebugInstrumentation
                .$beforeLocalAutomationSearchPublication.withValue({
                    do {
                        try await fixture.history.revokeCapability(.browsePreview, of: credential.connection)
                    } catch { Issue.record(error) }
                }) {
                    _ = try await fixture.ingress.execute(
                        .search(text: "sentinel", mode: .exact, limit: 10, cursor: nil),
                        presenting: credential.exactBytes
                    )
                }
        }
        let audit = try await fixture.history.auditLog(since: 1)
        #expect(audit.filter { $0.operationKind == .readSearch }.map(\.outcome) == [.denied])
    }

    @Test func revocationBeforeWriteCommitLeavesHistoryUnchanged() async throws {
        let fixture = try await makeFixture()
        let credential = fixture.credentials[0]
        let row = try #require(try await page(fixture).rows.first)
        try await fixture.history.grantCapability(.organize, to: credential.connection)
        let before = try await fixture.history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .organize, connectionID: credential.connection
        )) {
            try await ExternalGatewayDebugInstrumentation.$beforeLocalAutomationWriteCommit.withValue({
                do {
                    try await fixture.history.revokeCapability(.organize, of: credential.connection)
                } catch { Issue.record(error) }
            }) {
                _ = try await fixture.ingress.execute(.pin(locator: row.locator), presenting: credential.exactBytes)
            }
        }
        #expect(try await fixture.history.browse(HistoryBrowseRequest(kind: .recent, limit: 10)) == before)
    }
#endif

    private func page(_ fixture: Fixture, limit: Int = 10, cursor: String? = nil) async throws -> LocalAutomationPage {
        let result = try await fixture.ingress.execute(
            .recent(limit: limit, cursor: cursor), presenting: fixture.credentials[0].exactBytes
        )
        guard case .page(let page) = result else { throw ExternalFailure.persistence(.invariantViolation) }
        return page
    }

    private func makeFixture(
        itemCount: Int = 1, connectionCount: Int = 1,
        onCommittedRemoval: (@Sendable (HistoryItemID) async -> Void)? = nil
    ) async throws -> Fixture {
        let history = try await SwiftDataHistory.open(configuration: HistoryConfiguration(persistence: .memory))
        var credentials: [LocalAutomationCredential] = []
        for index in 0..<connectionCount {
            let connection = ExternalConnectionID(rawValue: UUID())
            try await history.authority.publishVerifiedLocalAutomationEnrollment(connection, displayName: "Ingress test")
            try await history.grantCapability(.browsePreview, to: connection)
            credentials.append(try LocalAutomationCredential(
                connection: connection, secret: Data(repeating: UInt8(index + 1), count: 32)
            ))
        }
        for index in 0..<itemCount {
            _ = try await history.perform(.capture(WSSupport.textCapture(
                "sentinel \(index)", observedAt: Date(timeIntervalSinceReferenceDate: 960_000_000 + Double(index))
            )))
        }
        let store = CredentialStore(operations: IngressMemoryCredentialOperations(
            values: Dictionary(uniqueKeysWithValues: credentials.map { ($0.connection, $0.exactBytes) })
        ))
        return Fixture(
            history: history,
            ingress: LocalAutomationIngress(
                authority: history.authority, gateway: history.externalGateway,
                credentialStore: store, onCommittedRemoval: onCommittedRemoval
            ),
            credentials: credentials, credentialStore: store
        )
    }
}

private actor IngressRemovalRecorder {
    private(set) var count = 0
    func record(_ itemID: HistoryItemID) { count += 1 }
}

private struct IngressMemoryCredentialOperations: CredentialStoreExternalOperations {
    var values: [ExternalConnectionID: Data]
    var unavailable = false

    mutating func connectionIDs() throws -> [ExternalConnectionID] { Array(values.keys) }
    mutating func addCredential(_ data: Data, for connection: ExternalConnectionID) -> CredentialStoreAddResult {
        guard values[connection] == nil else { return .duplicate }
        values[connection] = data
        return .stored
    }
    mutating func copyCredential(for connection: ExternalConnectionID) -> CredentialStoreCopyResult {
        if unavailable { return .unavailable }
        return values[connection].map(CredentialStoreCopyResult.value) ?? .missing
    }
    mutating func deleteCredential(for connection: ExternalConnectionID) -> CredentialStoreDeleteResult {
        values.removeValue(forKey: connection)
        return .deletedOrMissing
    }
}
