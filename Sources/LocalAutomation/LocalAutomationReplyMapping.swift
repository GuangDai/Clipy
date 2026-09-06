import ClipyCLIContract
import Foundation
import HistoryCore
import HistoryStorage

package enum LocalAutomationReplyMapping {
    package static func execute(
        json: Data, credential: Data, ingress: LocalAutomationIngress
    ) async -> LocalAutomationOutput {
        let request: ClipyCLIRequest
        switch ClipyCLIContract.decodeRequest(json) {
        case let .failure(failure): return .init(ClipyCLIContract.render(failure))
        case let .success(value): request = value
        }
        do {
            let result = try await ingress.execute(storageRequest(request), presenting: credential)
            let reply: ClipyCLIReply
            switch result {
            case let .page(page):
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                let items = try page.rows.map { row in
                    try ClipyCLIBrowsePreviewItem(
                        locator: row.locator, title: row.title,
                        typeIdentifiers: row.typeIdentifiers,
                        lastCopiedAt: formatter.string(from: row.lastCopiedAt),
                        pinned: row.pinned, snippet: row.snippet
                    )
                }
                reply = try .success(for: request, result: .init(items: items, nextCursor: page.nextCursor))
            case let .effective(content):
                let effective = try ClipyCLIEffectiveResult(
                    locator: content.locator,
                    representations: content.representations.map {
                        .init(typeIdentifier: $0.typeIdentifier, bytes: $0.bytes)
                    }
                )
                reply = .success(for: request, effective: effective)
            case .changed: reply = .success(for: request, changed: true)
            case .unchanged: reply = .success(for: request, changed: false)
            }
            return .init(ClipyCLIContract.render(reply))
        } catch {
            return .init(ClipyCLIContract.render(.failure(requestID: request.requestID, code: errorCode(error))))
        }
    }

    private static func storageRequest(_ request: ClipyCLIRequest) -> LocalAutomationRequest {
        switch request {
        case let .browsePreview(_, arguments):
            switch arguments {
            case let .recent(limit, cursor): .recent(limit: limit, cursor: cursor)
            case let .search(query, mode, limit, cursor):
                .search(text: query, mode: searchMode(mode), limit: limit, cursor: cursor)
            }
        case let .detailsEffective(_, locator): .detailsEffective(locator: locator)
        case let .pasteEffective(_, locator): .pasteEffective(locator: locator)
        case let .pin(_, locator): .pin(locator: locator)
        case let .unpin(_, locator): .unpin(locator: locator)
        case let .delete(_, locator): .delete(locator: locator)
        }
    }

    private static func searchMode(_ mode: ClipyCLISearchMode) -> SearchMode {
        switch mode { case .exact: .exact; case .fuzzy: .fuzzy; case .regexp: .regexp }
    }

    private static func errorCode(_ error: any Error) -> ClipyCLIErrorCode {
        if let failure = error as? LocalAutomationIngressFailure {
            return switch failure {
            case .authenticationFailed: .authenticationFailed
            case .locatorInvalidated: .locatorInvalidated
            case .cursorExpired: .cursorExpired
            }
        }
        if let failure = error as? ExternalFailure {
            switch failure {
            case .unauthorized: return .notGranted
            case .connectionRevoked: return .connectionRevoked
            case .notFound: return .notFound
            case .auditCompactedBefore: return .cursorExpired
            case let .temporarilyUnavailable(reason):
                return reason == .cancelled ? .cancelled : .busy
            case let .requestDenied(reason):
                return reason == .rateLimited ? .rateLimited : .invalidRequest
            case let .history(history): return historyErrorCode(history)
            case let .persistence(persistence):
                switch persistence {
                case .openStore: return .storeOpenFailed
                case .storeAlreadyOpen: return .notReady
                case .corruptStoredValue: return .corruptData
                case .invariantViolation: return .invariantViolation
                case .transaction: return .auditFailed
                }
            }
        }
        if let failure = error as? HistoryFailure { return historyErrorCode(failure) }
        if error is CancellationError { return .cancelled }
        if error is ClipyCLIValueFailure { return .responseTooLarge }
        return .invariantViolation
    }

    private static func historyErrorCode(_ failure: HistoryFailure) -> ClipyCLIErrorCode {
        switch failure {
        case .notFound, .revisionNotFound: .notFound
        case .staleContent: .contentStale
        case .snapshotExpired: .cursorExpired
        case .capacityExceeded: .responseTooLarge
        case .invalidInput, .invalidPinnedPlacement: .invalidRequest
        case .thumbnailUnavailable: .invalidRequest
        case .temporarilyUnavailable: .busy
        case let .persistence(reason):
            switch reason {
            case .openStore: .storeOpenFailed
            case .storeAlreadyOpen: .notReady
            case .corruptStoredValue: .corruptData
            case .invariantViolation: .invariantViolation
            case .transaction: .transactionFailed
            }
        }
    }
}
