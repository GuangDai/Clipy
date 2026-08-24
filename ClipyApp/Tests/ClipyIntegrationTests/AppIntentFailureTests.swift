/// Authorization precedence and content-free failure evidence for X.7.
import AppIntents
import Foundation
import HistoryCore
import Testing
@testable import ClipyApp

@Suite("App Intents failure boundary (X.7)")
struct AppIntentFailureTests {
    @Test("missing grant wins before poisoned regexp validation")
    func noGrantPrecedesInvalidRegexp() async throws {
        let support = try await AppIntentTestSupport.make()
        let intent = SearchHistoryIntent(
            query: "[private-query",
            mode: .regexp,
            limit: 20,
            history: support.ingress,
            dependencyManager: support.manager
        )

        await #expect(throws: ClipboardIntentFailure.permissionDenied) {
            _ = try await intent.perform()
        }
    }

    @Test("revoked connection is a content-free permission denial")
    func revokedConnectionIsDenied() async throws {
        let support = try await AppIntentTestSupport.make(
            grants: [.readContent]
        )
        let connectionID = try await support.appIntentsConnectionID()
        try await support.history.revokeConnection(connectionID)
        let intent = GetItemDetailsIntent(
            itemID: support.itemID.description,
            history: support.ingress,
            dependencyManager: support.manager
        )

        await #expect(throws: ClipboardIntentFailure.permissionDenied) {
            _ = try await intent.perform()
        }
    }

    @Test("invalid regexp is rejected after browse authorization")
    func invalidRegexpIsInvalidRequest() async throws {
        let support = try await AppIntentTestSupport.make(grants: [.browse])
        let intent = SearchHistoryIntent(
            query: "[private-query",
            mode: .regexp,
            limit: 20,
            history: support.ingress,
            dependencyManager: support.manager
        )

        await #expect(throws: ClipboardIntentFailure.invalidRequest) {
            _ = try await intent.perform()
        }
    }

    @Test("missing retained identity has one generic localized failure")
    func notFoundDoesNotExposeIdentity() async throws {
        let support = try await AppIntentTestSupport.make(
            grants: [.readContent]
        )
        let absentID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let intent = GetItemDetailsIntent(
            itemID: absentID,
            history: support.ingress,
            dependencyManager: support.manager
        )

        do {
            _ = try await intent.perform()
            Issue.record("expected absent item failure")
        } catch let failure as ClipboardIntentFailure {
            #expect(failure == .itemUnavailable)
            let description = failure.localizedDescription
            #expect(!description.contains(absentID))
            #expect(!description.contains("private-query"))
            #expect(!description.contains("intent-seed"))
            #expect(!description.contains("public.utf8-plain-text"))
            #expect(!description.contains("/"))
        }
    }

    @Test("malformed identity never reaches the Gateway")
    func malformedIdentityIsInvalidRequest() async throws {
        let support = try await AppIntentTestSupport.make(
            grants: [.readContent]
        )
        let intent = GetItemDetailsIntent(
            itemID: "not-an-identity",
            history: support.ingress,
            dependencyManager: support.manager
        )
        let auditBefore = try await support.history.auditLog(since: 1).filter {
            $0.operationKind != .adminReadAudit
        }

        await #expect(throws: ClipboardIntentFailure.invalidRequest) {
            _ = try await intent.perform()
        }
        let auditAfter = try await support.history.auditLog(since: 1).filter {
            $0.operationKind != .adminReadAudit
        }
        #expect(auditAfter == auditBefore)
    }
}
