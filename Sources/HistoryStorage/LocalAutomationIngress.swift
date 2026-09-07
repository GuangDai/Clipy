/// The app-owned Local Automation entry. Authentication, opaque process-local
/// locators, and short cursors stay beside the existing Gateway; transport
/// sees only bounded Effective-only values (REVIEW 07 §4/§10).
import Foundation
import HistoryCore

package enum LocalAutomationRequest: Sendable {
    case recent(limit: Int, cursor: String?)
    case search(text: String, mode: SearchMode, limit: Int, cursor: String?)
    case detailsEffective(locator: String)
    case pasteEffective(locator: String)
    case pin(locator: String)
    case unpin(locator: String)
    case delete(locator: String)
    case reviseContent(locator: String, expectedContentVersion: UInt64, representations: [HistoryRepresentation])
}

package struct LocalAutomationRow: Sendable {
    package let locator: String
    package let title: String
    package let typeIdentifiers: [String]
    package let lastCopiedAt: Date
    package let pinned: Bool
    package let snippet: String?
}

package struct LocalAutomationPage: Sendable {
    package let rows: [LocalAutomationRow]
    package let nextCursor: String?
}

package struct LocalAutomationEffectiveContent: Sendable {
    package let locator: String
    package let contentVersion: UInt64
    package let representations: [HistoryRepresentation]
}

package enum LocalAutomationResult: Sendable {
    case page(LocalAutomationPage)
    case effective(LocalAutomationEffectiveContent)
    case changed
    case unchanged
}

package enum LocalAutomationIngressFailure: Error, Sendable, Equatable {
    case authenticationFailed
    case locatorInvalidated
    case cursorExpired
}

/// Opaque outside the package: the application constructs one instance and
/// passes that same instance to its listener and enrollment UI.
public actor LocalAutomationIngress {
    internal let authority: HistoryAuthority
    internal let credentialStore: CredentialStore
    internal var isChangingEnrollment = false
    private let authenticator: LocalAutomationCredentialAuthenticator
    private let gateway: ExternalGateway
    private let onCommittedRemoval: (@Sendable (HistoryItemID) async -> Void)?
    private let onCommittedRevision: (@Sendable (HistoryItemReference, HistoryCommit) async -> Void)?

    private struct LocatorTarget: Hashable {
        let connection: ExternalConnectionID
        let itemID: HistoryItemID
    }

    private struct CursorTarget {
        let connection: ExternalConnectionID
        let kind: HistoryBrowseKind
        let limit: Int
        let cursor: HistoryPageCursor
    }

    // These values contain no clipboard content. FIFO eviction bounds the
    // process-local state; evicted or pre-restart tokens fail explicitly.
    // Locator capacity is independent of how many History items are retained:
    // distinct connections can hold distinct locators for the same item.
    private static let maximumLocatorCount = 5_000
    private var locators: [String: LocatorTarget] = [:]
    private var locatorByTarget: [LocatorTarget: String] = [:]
    private var locatorOrder: [String] = []
    private var cursors: [String: CursorTarget] = [:]
    private var cursorOrder: [String] = []

    internal init(
        authority: HistoryAuthority,
        gateway: ExternalGateway,
        credentialStore: CredentialStore,
        onCommittedRemoval: (@Sendable (HistoryItemID) async -> Void)? = nil,
        onCommittedRevision: (@Sendable (HistoryItemReference, HistoryCommit) async -> Void)? = nil
    ) {
        self.authority = authority
        self.gateway = gateway
        self.credentialStore = credentialStore
        self.onCommittedRemoval = onCommittedRemoval
        self.onCommittedRevision = onCommittedRevision
        authenticator = LocalAutomationCredentialAuthenticator(
            credentialStore: credentialStore, authority: authority
        )
    }

    package func execute(
        _ request: LocalAutomationRequest,
        presenting credential: Data
    ) async throws -> LocalAutomationResult {
        let authenticated: ExternalConnectionID?
        do {
            authenticated = try await authenticator.authenticate(credential)
        } catch let failure as CredentialStoreFailure {
            switch failure {
            case .unavailable:
                throw ExternalFailure.temporarilyUnavailable(.storeLocked)
            case .malformedCredential, .corruptStoredValue:
                throw ExternalFailure.persistence(.corruptStoredValue)
            case .duplicateCredential:
                throw ExternalFailure.persistence(.invariantViolation)
            }
        }
        guard let connection = authenticated else {
            throw LocalAutomationIngressFailure.authenticationFailed
        }
        try Task.checkCancellation()
        switch request {
        case .recent(let limit, let cursor):
            return try await browse(
                kind: .recent, limit: limit, cursor: cursor, connection: connection
            )
        case .search(let text, let mode, let limit, let cursor):
            return try await browse(
                kind: .search(text: text, mode: mode), limit: limit,
                cursor: cursor, connection: connection
            )
        case .detailsEffective(let locator), .pasteEffective(let locator):
            let itemID = try resolve(locator, connection: connection)
            let content = try await gateway.readLocalAutomationEffectiveContent(
                itemID, asAuthenticated: connection
            )
            try Task.checkCancellation()
            return .effective(LocalAutomationEffectiveContent(
                locator: locator, contentVersion: content.contentVersion,
                representations: content.representations
            ))
        case .reviseContent(let locator, let expected, let representations):
            let itemID = try resolve(locator, connection: connection)
            let receipt = try await gateway.reviseLocalAutomationContent(
                itemID, expectedContentVersion: expected, representations: representations,
                asAuthenticated: connection
            )
            guard case .committed(let commit) = receipt else { return .unchanged }
            guard case .revised = commit.outcome else {
                throw ExternalFailure.persistence(.invariantViolation)
            }
            let previous = HistoryItemReference(
                id: itemID, contentVersion: ContentVersion(rawValue: expected)
            )
            await onCommittedRevision?(previous, commit)
            return .changed
        case .pin(let locator), .unpin(let locator), .delete(let locator):
            let itemID = try resolve(locator, connection: connection)
            let mutation: ExternalRequest
            switch request {
            case .pin: mutation = .pin(itemID)
            case .unpin: mutation = .unpin(itemID)
            case .delete: mutation = .remove(itemID)
            case .recent, .search, .detailsEffective, .pasteEffective, .reviseContent:
                throw ExternalFailure.persistence(.invariantViolation)
            }
            let result = try await gateway.performLocalAutomation(
                mutation, asAuthenticated: connection
            )
            if case .unchanged = result { return .unchanged }
            if case .removed = result {
                await onCommittedRemoval?(itemID)
            }
            return .changed
        }
    }

    private func browse(
        kind: HistoryBrowseKind,
        limit: Int,
        cursor: String?,
        connection: ExternalConnectionID
    ) async throws -> LocalAutomationResult {
        let after: HistoryPageCursor?
        if let cursor {
            guard let target = cursors[cursor], target.connection == connection,
                  target.kind == kind, target.limit == limit else {
                throw LocalAutomationIngressFailure.cursorExpired
            }
            after = target.cursor
        } else {
            after = nil
        }
        let request: LocalAutomationBrowsePreviewRequest
        switch kind {
        case .recent:
            request = .recent(limit: limit, after: after)
        case .search(let text, let mode):
            request = .search(text: text, mode: mode, limit: limit, after: after)
        }
        let page: HistoryPage
        do {
            page = try await gateway.readLocalAutomationBrowsePreview(
                request, asAuthenticated: connection
            )
        } catch ExternalFailure.history(.snapshotExpired) {
            throw LocalAutomationIngressFailure.cursorExpired
        }
        try Task.checkCancellation()
        let rows = page.rows.map { row in
            LocalAutomationRow(
                locator: locator(for: row.item.id, connection: connection),
                title: row.title, typeIdentifiers: row.typeIdentifiers,
                lastCopiedAt: row.lastCopiedAt, pinned: row.pinnedPosition != nil,
                snippet: row.search?.snippet
            )
        }
        let nextCursor: String?
        if let next = page.next {
            let token = "c1_" + UUID().uuidString.lowercased()
            if cursorOrder.count == 64 {
                cursors.removeValue(forKey: cursorOrder.removeFirst())
            }
            cursors[token] = CursorTarget(
                connection: connection, kind: kind, limit: limit, cursor: next
            )
            cursorOrder.append(token)
            nextCursor = token
        } else {
            nextCursor = nil
        }
        return .page(LocalAutomationPage(rows: rows, nextCursor: nextCursor))
    }

    private func resolve(_ locator: String, connection: ExternalConnectionID) throws -> HistoryItemID {
        guard let target = locators[locator], target.connection == connection else {
            throw LocalAutomationIngressFailure.locatorInvalidated
        }
        return target.itemID
    }

    private func locator(for itemID: HistoryItemID, connection: ExternalConnectionID) -> String {
        let target = LocatorTarget(connection: connection, itemID: itemID)
        if let existing = locatorByTarget[target] { return existing }
        if locatorOrder.count == Self.maximumLocatorCount {
            let expired = locatorOrder.removeFirst()
            if let oldTarget = locators.removeValue(forKey: expired) {
                locatorByTarget.removeValue(forKey: oldTarget)
            }
        }
        let token = "i1_" + UUID().uuidString.lowercased()
        locators[token] = target
        locatorByTarget[target] = token
        locatorOrder.append(token)
        return token
    }
}

public extension SQLiteHistory {
    /// Call once per running app and share with its transport and Settings.
    func localAutomationIngress(
        onCommittedRemoval: (@Sendable (HistoryItemID) async -> Void)? = nil,
        onCommittedRevision: (@Sendable (HistoryItemReference, HistoryCommit) async -> Void)? = nil
    ) -> LocalAutomationIngress {
        LocalAutomationIngress(
            authority: authority, gateway: externalGateway, credentialStore: CredentialStore(),
            onCommittedRemoval: onCommittedRemoval,
            onCommittedRevision: onCommittedRevision
        )
    }
}
