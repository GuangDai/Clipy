/// X.5 internal in-process Gateway denial substrate.
/// Owning spec: `V2-05` §3.1/§4.5/§6.2 and roadmap X.5.
///
/// The actor owns only process-local admission state and immutable actor/value
/// references. It never creates a ModelContext: live connection/grant
/// authorization and every durable denial audit remain Authority-owned.
import Dispatch
import HistoryCore

internal actor ExternalGateway {
    private let authority: HistoryAuthority
    private let appIntentsConnectionID: ExternalConnectionID
    private var rateLimiter: ExternalRateLimiter
    private let limits: ExternalLimits
    private var admittedOperationsSinceCompaction = 0
    private let uptimeNanoseconds: @Sendable () -> UInt64

    /// Production construction samples uptime once for the initially-full
    /// bucket. `SwiftDataHistory.open` wires this only after startup succeeds.
    internal init(
        authority: HistoryAuthority,
        appIntentsConnectionID: ExternalConnectionID
    ) {
        let initialUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        self.authority = authority
        self.appIntentsConnectionID = appIntentsConnectionID
        self.rateLimiter = ExternalRateLimiter(
            initialUptimeNanoseconds: initialUptimeNanoseconds
        )
        self.limits = .standard
        self.uptimeNanoseconds = {
            DispatchTime.now().uptimeNanoseconds
        }
    }

    internal init(
        authority: HistoryAuthority,
        appIntentsConnectionID: ExternalConnectionID,
        rateLimiter: ExternalRateLimiter,
        limits: ExternalLimits = .standard,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.authority = authority
        self.appIntentsConnectionID = appIntentsConnectionID
        self.rateLimiter = rateLimiter
        self.limits = limits
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    /// Validates and authorizes one closed external mutation request without
    /// dispatching it. X.6 adds the granted positive path before any public
    /// facade exists; X.5 exposes no unavailable or synthetic dispatcher.
    internal func authorize(
        _ request: ExternalRequest,
        as connection: ExternalConnectionID
    ) async throws {
        try requireKnownConnection(connection, capability: .manage)
        try await authorizeKnownDescriptor(
            Self.descriptor(for: request),
            as: connection
        )
    }

    /// Validates and authorizes one closed external read without evaluating
    /// History. Bounds fail before the Authority and therefore append no audit;
    /// rate and authorization denials use the real Authority audit barrier.
    internal func authorize(
        _ read: ExternalRead,
        as connection: ExternalConnectionID
    ) async throws {
        let capability = Self.requiredCapability(for: read)
        try requireKnownConnection(connection, capability: capability)
        try await authorizeKnownDescriptor(
            Self.descriptor(for: read),
            as: connection
        )
    }

    internal func authorize(
        _ descriptor: ExternalOperationDescriptor,
        as connection: ExternalConnectionID
    ) async throws {
        try requireKnownConnection(
            connection,
            capability: descriptor.capability
        )
        try await authorizeKnownDescriptor(descriptor, as: connection)
    }

    private func authorizeKnownDescriptor(
        _ descriptor: ExternalOperationDescriptor,
        as connection: ExternalConnectionID
    ) async throws {
        // The caller has already matched the startup-baked identity. A
        // forbidden descriptor pair is likewise a pure, unaudited admission
        // failure and consumes no process quota.
        guard descriptor.requestMatchesOperation,
              ExternalAccessPolicy.admits(
                connectionKind: .appIntents,
                capability: descriptor.capability,
                operation: descriptor.operationKind
              ) else {
            throw ExternalFailure.requestDenied(.invalidInput)
        }
        admittedOperationsSinceCompaction += 1
        let shouldCompact = admittedOperationsSinceCompaction
            == limits.compactionCadenceOps
        if shouldCompact {
            admittedOperationsSinceCompaction = 0
        }

        guard rateLimiter.admit(
            atUptimeNanoseconds: uptimeNanoseconds()
        ) else {
            try await authority.commitExternalRateDenial(
                descriptor,
                as: connection
            )
            if shouldCompact {
                try await authority.compactExternalAuditIfNeeded(limits: limits)
            }
            throw ExternalFailure.requestDenied(.rateLimited)
        }

        do {
            try await authority.authorizeExternal(descriptor, as: connection)
        } catch {
            if shouldCompact {
                try await authority.compactExternalAuditIfNeeded(limits: limits)
            }
            throw error
        }
        if shouldCompact {
            try await authority.compactExternalAuditIfNeeded(limits: limits)
        }
    }

    private func requireKnownConnection(
        _ connection: ExternalConnectionID,
        capability: ExternalCapability
    ) throws {
        guard connection == appIntentsConnectionID else {
            throw ExternalFailure.unauthorized(
                requestedCapability: capability,
                connectionID: connection
            )
        }
    }

    private static func requiredCapability(
        for read: ExternalRead
    ) -> ExternalCapability {
        switch read {
        case .recent, .search:
            .browse
        case .details, .pastePayload:
            .readContent
        }
    }

    private static func descriptor(
        for request: ExternalRequest
    ) -> ExternalOperationDescriptor {
        switch request {
        case .pin(let id):
            ExternalOperationDescriptor(
                capability: .manage,
                operationKind: .managePin,
                requestSummary: .pin(itemID: id.rawValue)
            )
        case .unpin(let id):
            ExternalOperationDescriptor(
                capability: .manage,
                operationKind: .manageUnpin,
                requestSummary: .unpin(itemID: id.rawValue)
            )
        case .remove(let id):
            ExternalOperationDescriptor(
                capability: .manage,
                operationKind: .manageRemove,
                requestSummary: .remove(itemID: id.rawValue)
            )
        }
    }

    private static func descriptor(
        for read: ExternalRead,
        limits: HistoryLimits = .standard
    ) throws -> ExternalOperationDescriptor {
        switch read {
        case .recent(let limit):
            return ExternalOperationDescriptor(
                capability: .browse,
                operationKind: .readRecent,
                requestSummary: .recent(
                    limit: try encodedLimit(limit, limits: limits)
                )
            )

        case .search(let text, let mode, let limit):
            guard text.utf8.count <= limits.maximumSearchTermUTF8Bytes else {
                throw ExternalFailure.requestDenied(.invalidInput)
            }
            let encodedMode: SearchModeRawV1
            switch mode {
            case .exact:
                encodedMode = .exact
            case .fuzzy:
                guard text.count <= limits.maximumFuzzyQueryCharacters else {
                    throw ExternalFailure.requestDenied(.invalidInput)
                }
                encodedMode = .fuzzy
            case .regexp:
                guard text.count <= limits.maximumRegexpPatternCharacters else {
                    throw ExternalFailure.requestDenied(.invalidInput)
                }
                encodedMode = .regexp
            }
            guard let queryByteCount = UInt16(exactly: text.utf8.count) else {
                throw ExternalFailure.requestDenied(.invalidInput)
            }
            return ExternalOperationDescriptor(
                capability: .browse,
                operationKind: .readSearch,
                requestSummary: .search(
                    queryUTF8ByteCount: queryByteCount,
                    mode: encodedMode,
                    limit: try encodedLimit(limit, limits: limits)
                )
            )

        case .details(let id):
            return ExternalOperationDescriptor(
                capability: .readContent,
                operationKind: .readDetails,
                requestSummary: .details(itemID: id.rawValue)
            )

        case .pastePayload(let id):
            return ExternalOperationDescriptor(
                capability: .readContent,
                operationKind: .readPastePayload,
                requestSummary: .pastePayload(itemID: id.rawValue)
            )
        }
    }

    private static func encodedLimit(
        _ limit: Int,
        limits: HistoryLimits
    ) throws -> UInt16 {
        guard limits.pageRowLimitRange.contains(limit),
              let encoded = UInt16(exactly: limit) else {
            throw ExternalFailure.requestDenied(.invalidInput)
        }
        return encoded
    }
}
