import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("Local Automation full Effective revision", .serialized)
struct LocalAutomationRevisionTests {
    private static let opaqueType = "com.example.opaque"
    private static let initial: [HistoryRepresentation] = [
        HistoryRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("original".utf8)),
        HistoryRepresentation(typeIdentifier: opaqueType, bytes: Data([1, 2])),
    ]

    private struct Fixture: Sendable {
        let history: SQLiteHistory
        let ingress: LocalAutomationIngress
        let credential: LocalAutomationCredential
        let item: HistoryItemReference
        let locator: String
    }

    @Test func fullReplacementPreservesCanonicalAndNoOpDoesNotAppend() async throws {
        let fixture = try await makeFixture()
        let proposed = [HistoryRepresentation(typeIdentifier: Self.opaqueType, bytes: Data([0, 0xFF, 3]))]
        let before = try await fixture.history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        guard case .changed = try await revise(fixture, expected: 1, representations: proposed) else {
            Issue.record("Expected an external revision commit")
            return
        }
        let content = try await effective(fixture)
        #expect(content.contentVersion == 2)
        #expect(content.representations == proposed)
        let details = try await fixture.history.details(for: fixture.item.id)
        #expect(details.canonical.count == 2)
        #expect(details.canonical.contains { $0.bytes == Data("original".utf8) })
        #expect(details.revisions.count == 1)
        #expect(details.effective == proposed)
        let committed = try await fixture.history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(committed.position.rawValue == before.position.rawValue + 1)
        await #expect(throws: ExternalFailure.history(.staleContent(
            expected: ContentVersion(rawValue: 1), current: ContentVersion(rawValue: 2)
        ))) {
            _ = try await revise(fixture, expected: 1, representations: proposed)
        }
        guard case .unchanged = try await revise(fixture, expected: 2, representations: proposed) else {
            Issue.record("Byte-identical full replacement must not append")
            return
        }
        #expect(try await fixture.history.browse(HistoryBrowseRequest(kind: .recent, limit: 10)) == committed)
        #expect(try await fixture.history.details(for: fixture.item.id).revisions.count == 1)
        // Fresh stores retain audit sequences starting at 1; `since` is inclusive.
        let audit = try await fixture.history.auditLog(since: 1).filter { $0.operationKind == .reviseContent }
        #expect(audit.map(\.outcome) == [.succeeded, .failed, .noOp])
        #expect(audit[0].changePosition == committed.position)
        #expect(audit[1].changePosition == nil && audit[2].changePosition == nil)
        #expect(audit.allSatisfy { $0.capability == .reviseContent })
    }

    @Test func independentGrantAllowsWriteWithoutImplicitReadOrDelete() async throws {
        let fixture = try await makeFixture(grantRevision: false)
        let proposed = [HistoryRepresentation(typeIdentifier: Self.opaqueType, bytes: Data([9]))]
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .reviseContent, connectionID: fixture.credential.connection
        )) { _ = try await revise(fixture, expected: 1, representations: proposed) }
        try await fixture.history.grantCapability(.reviseContent, to: fixture.credential.connection)
        try await fixture.history.revokeCapability(.browsePreview, of: fixture.credential.connection)
        try await fixture.history.revokeCapability(.readEffectiveContent, of: fixture.credential.connection)
        _ = try await revise(fixture, expected: 1, representations: proposed)
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .readEffectiveContent, connectionID: fixture.credential.connection
        )) { _ = try await effective(fixture) }
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .deleteItem, connectionID: fixture.credential.connection
        )) {
            _ = try await fixture.ingress.execute(.delete(locator: fixture.locator), presenting: fixture.credential.exactBytes)
        }
        #expect(try await fixture.history.details(for: fixture.item.id).effective == proposed)
    }

    @Test func emptyDuplicateAndForeignSetsNeverCreateARevision() async throws {
        let fixture = try await makeFixture()
        let value = HistoryRepresentation(typeIdentifier: Self.opaqueType, bytes: Data([3]))
        let invalid: [[HistoryRepresentation]] = [
            [], [value, value],
            [HistoryRepresentation(typeIdentifier: "foreign.type", bytes: Data([3]))],
            [HistoryRepresentation(typeIdentifier: Self.opaqueType, bytes: Data())],
        ]
        for representations in invalid {
            await #expect(throws: ExternalFailure.history(.invalidInput(.incoherentRevisionDraft))) {
                _ = try await revise(fixture, expected: 1, representations: representations)
            }
        }
        #expect(try await fixture.history.details(for: fixture.item.id).revisions.isEmpty)
    }

#if DEBUG
    @Test(arguments: [false, true])
    func revocationAfterPreparationPreventsChangedAndNoOpWrites(_ changed: Bool) async throws {
        let fixture = try await makeFixture()
        let representations = changed
            ? [HistoryRepresentation(typeIdentifier: Self.opaqueType, bytes: Data([3]))]
            : Self.initial
        await #expect(throws: ExternalFailure.unauthorized(
            requestedCapability: .reviseContent, connectionID: fixture.credential.connection
        )) {
            try await ExternalGatewayDebugInstrumentation.$beforeLocalAutomationWriteCommit.withValue({
                do {
                    try await fixture.history.revokeCapability(.reviseContent, of: fixture.credential.connection)
                } catch { Issue.record(error) }
            }) {
                _ = try await revise(fixture, expected: 1, representations: representations)
            }
        }
        #expect(try await fixture.history.details(for: fixture.item.id).revisions.isEmpty)
        let audit = try await fixture.history.auditLog(since: 1).filter { $0.operationKind == .reviseContent }
        #expect(audit.map(\.outcome) == [.denied])
    }

    @Test func concurrentUIRevisionWinsOCCWithoutExternalOverwrite() async throws {
        let fixture = try await makeFixture()
        await #expect(throws: ExternalFailure.history(.staleContent(
            expected: ContentVersion(rawValue: 1), current: ContentVersion(rawValue: 2)
        ))) {
            try await ExternalGatewayDebugInstrumentation.$beforeLocalAutomationWriteCommit.withValue({
                do {
                    _ = try await fixture.history.perform(.revise(RevisionRequest(
                        itemID: fixture.item.id, expected: fixture.item.contentVersion,
                        intent: .replace(RevisionDraft(decisions: [
                            RevisionDecision(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data("UI wins".utf8))),
                            RevisionDecision(typeIdentifier: Self.opaqueType, action: .inheritCanonical),
                        ]))
                    )))
                } catch { Issue.record(error) }
            }) {
                _ = try await revise(fixture, expected: 1, representations: [
                    HistoryRepresentation(typeIdentifier: Self.opaqueType, bytes: Data([9])),
                ])
            }
        }
        let details = try await fixture.history.details(for: fixture.item.id)
        #expect(details.revisions.count == 1)
        #expect(details.effective.contains { $0.bytes == Data("UI wins".utf8) })
        let audit = try await fixture.history.auditLog(since: 1).filter { $0.operationKind == .reviseContent }
        #expect(audit.map(\.outcome) == [.failed])
    }
#endif

    @Test(arguments: [InjectedTransactionFailure.beforeHCRAppend, .beforeSingletonUpdate])
    func transactionFailureRollsBackRevisionAndSuccessfulAuditTogether(
        _ injection: InjectedTransactionFailure
    ) async throws {
        let fixture = try await makeFixture()
        let before = try await fixture.history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        await fixture.history.authority.setTransactionFailureInjection(injection)
        await #expect(throws: ExternalFailure.persistence(.transaction)) {
            _ = try await revise(fixture, expected: 1, representations: [
                HistoryRepresentation(typeIdentifier: Self.opaqueType, bytes: Data([9])),
            ])
        }
        #expect(try await fixture.history.browse(HistoryBrowseRequest(kind: .recent, limit: 10)) == before)
        #expect(try await fixture.history.details(for: fixture.item.id).revisions.isEmpty)
        let audit = try await fixture.history.auditLog(since: 1).filter { $0.operationKind == .reviseContent }
        #expect(audit.map(\.outcome) == [.failed])
    }

    @Test func r2RetirementAndR3PruningShareTheRevisionCommitAndPurgeCallback() async throws {
        let callbacks = RevisionPurgeRecorder()
        let fixture = try await makeFixture(seedOlderItem: true, onCommittedRevision: {
            await callbacks.record($0, commit: $1)
        })
        // Canonical target = 10 bytes, older item = 5. Six revision bytes
        // exceed this budget by one, so the older item retires atomically.
        _ = try await fixture.history.perform(.setRetentionPolicies(HistoryRetentionPolicies(
            age: nil, storage: StorageRetention(maxTotalBytes: 20),
            revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
        )))
        _ = try await revise(fixture, expected: 1, representations: [
            HistoryRepresentation(typeIdentifier: Self.opaqueType, bytes: Data(repeating: 6, count: 6)),
        ])
        #expect(try await fixture.history.browse(HistoryBrowseRequest(kind: .recent, limit: 10)).rows.count == 1)
        _ = try await revise(fixture, expected: 2, representations: [
            HistoryRepresentation(typeIdentifier: Self.opaqueType, bytes: Data(repeating: 7, count: 7)),
        ])
        let details = try await fixture.history.details(for: fixture.item.id)
        #expect(details.revisions.count == 1)
        #expect(details.item.contentVersion.rawValue == 3)
        #expect(await callbacks.versions == [2, 3])
        #expect(await callbacks.previousVersions == [1, 2])
        #expect(await callbacks.destructive == [true, true])
        let audit = try await fixture.history.auditLog(since: 1).filter { $0.operationKind == .reviseContent }
        #expect(audit.map(\.outcome) == [.succeeded, .succeeded])
        let finalPage = try await fixture.history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(audit.last?.changePosition == finalPage.position)
    }

    private func revise(_ fixture: Fixture, expected: UInt64, representations: [HistoryRepresentation]) async throws -> LocalAutomationResult {
        try await fixture.ingress.execute(
            .reviseContent(locator: fixture.locator, expectedContentVersion: expected, representations: representations),
            presenting: fixture.credential.exactBytes
        )
    }

    private func effective(_ fixture: Fixture) async throws -> LocalAutomationEffectiveContent {
        guard case .effective(let result) = try await fixture.ingress.execute(
            .detailsEffective(locator: fixture.locator), presenting: fixture.credential.exactBytes
        ) else { throw ExternalFailure.persistence(.invariantViolation) }
        return result
    }

    private func makeFixture(
        grantRevision: Bool = true, seedOlderItem: Bool = false,
        onCommittedRevision: (@Sendable (HistoryItemReference, HistoryCommit) async -> Void)? = nil
    ) async throws -> Fixture {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        let connection = ExternalConnectionID(rawValue: UUID())
        try await history.authority.publishVerifiedLocalAutomationEnrollment(connection, displayName: "Revision test")
        for capability in [ExternalCapability.browsePreview, .readEffectiveContent] {
            try await history.grantCapability(capability, to: connection)
        }
        if grantRevision { try await history.grantCapability(.reviseContent, to: connection) }
        if seedOlderItem {
            _ = try await history.perform(.capture(WSSupport.textCapture("older", observedAt: Date(timeIntervalSinceReferenceDate: 970_000_000))))
        }
        _ = try await history.perform(.capture(ClipboardCapture(
            representations: Self.initial.map { CapturedRepresentation(typeIdentifier: $0.typeIdentifier, bytes: $0.bytes) },
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 970_000_001)
        )))
        let item = try #require(try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 1)).rows.first?.item)
        let credential = try LocalAutomationCredential(connection: connection, secret: Data(repeating: 55, count: 32))
        let store = CredentialStore(operations: RevisionMemoryCredentials(values: [connection: credential.exactBytes]))
        let ingress = LocalAutomationIngress(
            authority: history.authority, gateway: history.externalGateway, credentialStore: store,
            onCommittedRevision: onCommittedRevision
        )
        guard case .page(let page) = try await ingress.execute(.recent(limit: 1, cursor: nil), presenting: credential.exactBytes),
              let locator = page.rows.first?.locator else {
            throw ExternalFailure.persistence(.invariantViolation)
        }
        return Fixture(history: history, ingress: ingress, credential: credential, item: item, locator: locator)
    }
}

private actor RevisionPurgeRecorder {
    private(set) var versions: [UInt64] = []
    private(set) var previousVersions: [UInt64] = []
    private(set) var destructive: [Bool] = []
    func record(_ previous: HistoryItemReference, commit: HistoryCommit) {
        guard case .revised(let reference) = commit.outcome else {
            Issue.record("Expected a committed revision callback")
            return
        }
        versions.append(reference.contentVersion.rawValue)
        previousVersions.append(previous.contentVersion.rawValue)
        destructive.append(commit.hasDestructiveRetentionEffects)
    }
}

private struct RevisionMemoryCredentials: CredentialStoreExternalOperations {
    var values: [ExternalConnectionID: Data]
    mutating func connectionIDs() throws -> [ExternalConnectionID] { Array(values.keys) }
    mutating func addCredential(_ data: Data, for connection: ExternalConnectionID) -> CredentialStoreAddResult {
        guard values[connection] == nil else { return .duplicate }
        values[connection] = data
        return .stored
    }
    mutating func copyCredential(for connection: ExternalConnectionID) -> CredentialStoreCopyResult {
        values[connection].map(CredentialStoreCopyResult.value) ?? .missing
    }
    mutating func deleteCredential(for connection: ExternalConnectionID) -> CredentialStoreDeleteResult {
        values.removeValue(forKey: connection)
        return .deletedOrMissing
    }
}
