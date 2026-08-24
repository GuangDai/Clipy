/// X.5/X.6 internal in-process Gateway admission and dispatch actor.
/// Owning spec: `V2-05` §3.1/§4.5/§5/§6.2 and roadmap X.5–X.6.
///
/// The actor owns only process-local admission state and immutable actor/value
/// references. It never creates a ModelContext: live connection/grant
/// authorization and every durable denial audit remain Authority-owned.
import Dispatch
import Foundation
import HistoryCore

#if DEBUG
internal enum ExternalGatewayDebugInstrumentation {
    @TaskLocal internal static var compactionFollowerDidJoin:
        (@Sendable () async -> Void)?
}
#endif

private final class ExternalAuditCompactionAttempt: Sendable {
    let task: Task<Void, Error>

    init(authority: HistoryAuthority, limits: ExternalLimits) {
        task = Task {
            try await authority.compactExternalAuditIfNeeded(limits: limits)
        }
    }
}

internal actor ExternalGateway {
    private let authority: HistoryAuthority
    private let appIntentsConnectionID: ExternalConnectionID
    private let searchWorker: SearchWorker
    private let storageClock: any StorageClock
    private var rateLimiter: ExternalRateLimiter
    private let limits: ExternalLimits
    private var admittedOperationsSinceCompaction = 0
    private var pendingCompaction: ExternalAuditCompactionAttempt?
    private let uptimeNanoseconds: @Sendable () -> UInt64

    /// Production construction samples uptime once for the initially-full
    /// bucket. `SwiftDataHistory.open` wires this only after startup succeeds.
    internal init(
        authority: HistoryAuthority,
        appIntentsConnectionID: ExternalConnectionID,
        searchWorker: SearchWorker,
        storageClock: any StorageClock
    ) {
        let initialUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        self.authority = authority
        self.appIntentsConnectionID = appIntentsConnectionID
        self.searchWorker = searchWorker
        self.storageClock = storageClock
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
        searchWorker: SearchWorker,
        storageClock: any StorageClock,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.authority = authority
        self.appIntentsConnectionID = appIntentsConnectionID
        self.searchWorker = searchWorker
        self.storageClock = storageClock
        self.rateLimiter = rateLimiter
        self.limits = limits
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    /// X.5 test seam: validates and authorizes one closed external mutation
    /// request without dispatching it. Public X.6 calls use `perform` below.
    internal func authorize(
        _ request: ExternalRequest,
        as connection: ExternalConnectionID
    ) async throws {
        let requestedAt = storageClock.now()
        try requireKnownConnection(connection, capability: .manage)
        try await authorizeKnownDescriptor(
            ExternalOperationDescriptor.forRequest(request),
            as: connection,
            expectedConnectionKind: .appIntents,
            requestedAt: requestedAt
        )
    }

    /// Runs one admitted manage request through the Authority's sole
    /// save-boundary gate and audited commit path (`V2-05` §5.1/§6.3).
    internal func perform(
        _ request: ExternalRequest,
        as connection: ExternalConnectionID
    ) async throws -> ExternalResponse {
        let requestedAt = storageClock.now()
        try requireKnownConnection(connection, capability: .manage)
        let descriptor = ExternalOperationDescriptor.forRequest(request)
        try await beginAdmittedOperation(
            descriptor,
            as: connection,
            expectedConnectionKind: .appIntents,
            requestedAt: requestedAt
        )
        return try await authority.commitExternal(
            request: request,
            connection: connection,
            expectedConnectionKind: .appIntents,
            requestedAt: requestedAt
        )
    }

    /// Validates and authorizes one closed external read without evaluating
    /// History. Bounds fail before the Authority and therefore append no audit;
    /// rate and authorization denials use the real Authority audit barrier.
    internal func authorize(
        _ read: ExternalRead,
        as connection: ExternalConnectionID
    ) async throws {
        let requestedAt = storageClock.now()
        let capability = ExternalOperationDescriptor.requiredCapability(
            for: read
        )
        try requireKnownConnection(connection, capability: capability)
        try await authorizeKnownDescriptor(
            ExternalOperationDescriptor.forRead(read),
            as: connection,
            expectedConnectionKind: .appIntents,
            requestedAt: requestedAt
        )
    }

    /// Runs one admitted external read through the Authority-owned live gate,
    /// projection, and mandatory audit publication barrier (`V2-05` §5.2).
    internal func read(
        _ request: ExternalRead,
        as connection: ExternalConnectionID
    ) async throws -> ExternalReadResult {
        let requestedAt = storageClock.now()
        let capability = ExternalOperationDescriptor.requiredCapability(
            for: request
        )
        try requireKnownConnection(connection, capability: capability)
        let descriptor = try ExternalOperationDescriptor.forRead(request)
        try await beginAdmittedOperation(
            descriptor,
            as: connection,
            expectedConnectionKind: .appIntents,
            requestedAt: requestedAt
        )
        return try await authority.performExternalRead(
            request,
            connection: connection,
            expectedConnectionKind: .appIntents,
            requestedAt: requestedAt,
            searchWorker: searchWorker
        )
    }

    /// The post-authentication Local Automation read entry. The caller cannot
    /// select a kind or capability: this route is closed over recent/search,
    /// excludes details/paste payload, and fixes the pair to
    /// `.localAutomation + .browsePreview`. The Authority
    /// still rechecks the durable kind, status, and live grant immediately
    /// before projection, so authentication never becomes authorization.
    internal func readLocalAutomationBrowsePreview(
        _ request: LocalAutomationBrowsePreviewRequest,
        asAuthenticated connection: ExternalConnectionID
    ) async throws -> HistoryPage {
        let requestedAt = storageClock.now()
        let read = request.externalRead
        let descriptor = try ExternalOperationDescriptor.forRead(
            read,
            expectedConnectionKind: .localAutomation
        )
        // V2-05's existing bucket is explicitly App-Intents-only. F1 has not
        // frozen a Local Automation quota, so this unpublished pre-transport
        // join shares structural admission/cadence but never consumes or
        // perturbs that bucket.
        try await beginStructurallyAdmittedOperation(
            descriptor,
            expectedConnectionKind: .localAutomation
        )
        return try await authority.performLocalAutomationBrowsePreview(
            read,
            connection: connection,
            requestedAt: requestedAt,
            searchWorker: searchWorker
        )
    }

    internal func authorize(
        _ descriptor: ExternalOperationDescriptor,
        as connection: ExternalConnectionID
    ) async throws {
        let requestedAt = storageClock.now()
        try requireKnownConnection(
            connection,
            capability: descriptor.capability
        )
        try await authorizeKnownDescriptor(
            descriptor,
            as: connection,
            expectedConnectionKind: .appIntents,
            requestedAt: requestedAt
        )
    }

    private func authorizeKnownDescriptor(
        _ descriptor: ExternalOperationDescriptor,
        as connection: ExternalConnectionID,
        expectedConnectionKind: ConnectionEnrollKind,
        requestedAt: Date
    ) async throws {
        try await beginAdmittedOperation(
            descriptor,
            as: connection,
            expectedConnectionKind: expectedConnectionKind,
            requestedAt: requestedAt
        )
        try await authority.authorizeExternal(
            descriptor,
            as: connection,
            expectedConnectionKind: expectedConnectionKind,
            requestedAt: requestedAt
        )
    }

    /// Applies pure pair admission, the retryable pre-dispatch maintenance
    /// cadence, and one process-local token debit. A successful return has not
    /// performed any durable grant lookup; the X.5 authorize wrapper or one
    /// X.6 Authority operation owns that single gate.
    private func beginAdmittedOperation(
        _ descriptor: ExternalOperationDescriptor,
        as connection: ExternalConnectionID,
        expectedConnectionKind: ConnectionEnrollKind,
        requestedAt: Date
    ) async throws {
        try await beginStructurallyAdmittedOperation(
            descriptor,
            expectedConnectionKind: expectedConnectionKind
        )

        guard rateLimiter.admit(
            atUptimeNanoseconds: uptimeNanoseconds()
        ) else {
            try await authority.commitExternalRateDenial(
                descriptor,
                as: connection,
                expectedConnectionKind: expectedConnectionKind,
                requestedAt: requestedAt
            )
            throw ExternalFailure.requestDenied(.rateLimited)
        }
    }

    /// Pure pair admission plus the global audit-maintenance cadence. The
    /// existing App Intents wrapper adds its separately frozen token debit;
    /// the internal F1 join stops here until its own quota policy is approved.
    private func beginStructurallyAdmittedOperation(
        _ descriptor: ExternalOperationDescriptor,
        expectedConnectionKind: ConnectionEnrollKind
    ) async throws {
        // The owning entry has already established identity: App Intents
        // matched the startup-baked ID, while F1 authenticated exact custody
        // bytes and a durable Local Automation row. A forbidden descriptor
        // pair is a pure, unaudited admission failure.
        guard descriptor.requestMatchesOperation,
              ExternalAccessPolicy.admits(
                connectionKind: expectedConnectionKind,
                capability: descriptor.capability,
                operation: descriptor.operationKind
              ) else {
            throw ExternalFailure.requestDenied(.invalidInput)
        }
        try await advanceCompactionCadence()
    }

    /// Serializes the cadence barrier across actor reentrancy. The request
    /// that creates an attempt is the Nth request; requests that join it count
    /// against the next interval only after the shared maintenance succeeds.
    private func advanceCompactionCadence() async throws {
        while true {
            if let attempt = pendingCompaction {
#if DEBUG
                await ExternalGatewayDebugInstrumentation
                    .compactionFollowerDidJoin?()
#endif
                do {
                    try await attempt.task.value
                } catch {
                    if pendingCompaction === attempt {
                        pendingCompaction = nil
                        admittedOperationsSinceCompaction =
                            limits.compactionCadenceOps - 1
                    }
                    throw error
                }
                if pendingCompaction === attempt {
                    pendingCompaction = nil
                    admittedOperationsSinceCompaction = 0
                }
                // This request joined the Nth request's barrier, so it still
                // belongs to the newly opened cadence interval.
                continue
            }

            guard admittedOperationsSinceCompaction
                    == limits.compactionCadenceOps - 1 else {
                admittedOperationsSinceCompaction += 1
                return
            }

            let attempt = ExternalAuditCompactionAttempt(
                authority: authority,
                limits: limits
            )
            pendingCompaction = attempt
            do {
                try await attempt.task.value
            } catch {
                if pendingCompaction === attempt {
                    pendingCompaction = nil
                    // Preserve N - 1 so the next request retries maintenance.
                    admittedOperationsSinceCompaction =
                        limits.compactionCadenceOps - 1
                }
                throw error
            }
            if pendingCompaction === attempt {
                pendingCompaction = nil
                admittedOperationsSinceCompaction = 0
            }
            return
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

}
