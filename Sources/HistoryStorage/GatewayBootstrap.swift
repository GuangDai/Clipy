/// X.3 Gateway bootstrap (`V2-roadmap` §10 X.3; `V2-05` §4.6).
///
/// This is deliberately only the deny-by-default startup slice. The current
/// release has no Gateway writer or audit appender, so every open requires
/// exactly one config row, exactly one matching active App Intents connection,
/// and zero grant/audit rows. X.4 must replace the exact-zero audit rule with
/// its complete row/counter validation in the same change that introduces the
/// first audit writer. No hash or audit-chain validation belongs to this
/// resolved schema.
import Foundation
import HistoryCore
import SwiftData

extension HistoryAuthority {
    internal static let gatewayConfigKey = "external-gateway"
    internal static let gatewayConfigSchemaVersion: UInt16 = 1
    internal static let gatewayConnectionDisplayName =
        "Siri / Shortcuts / Spotlight"

    /// Bootstraps or validates the complete X.3 Gateway table shape.
    ///
    /// Absence is a migration-compatible create path only when all four
    /// Gateway tables are empty. The config singleton and its matching
    /// active App Intents connection are inserted in one transaction/save
    /// boundary before facade publication; no grant is created. Once config
    /// exists, its durable connection identity is authoritative and is never
    /// re-minted or repaired. Every fetch is unfiltered over the whole table,
    /// with the smallest limit that distinguishes the required cardinality,
    /// so wrong-key and unrelated extra rows cannot masquerade as absence.
    ///
    /// Unknown schema/raw values are corrupt stored values. Known but
    /// forbidden lifecycle states, broken identity/counter relations, and
    /// wrong cardinality are invariant violations. Fetch/create failures use
    /// the startup `.openStore` producer, matching the other startup
    /// singletons. (`V2-05` §4.1/§4.6; `05` §13/§16.)
    internal func ensureGatewayBootstrap(in context: ModelContext) throws {
        var configDescriptor = FetchDescriptor<GatewayConfigRow>()
        configDescriptor.fetchLimit = 2
        let configs: [GatewayConfigRow]
        do {
            configs = try context.fetch(configDescriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }

        switch configs.count {
        case 0:
            guard try Self.gatewayTablesAreEmpty(in: context) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            let connectionID = gatewayConnectionIDSource()
            let enrolledAt = storageClock.now()
            do {
                try context.transaction {
                    context.insert(GatewayConfigRow(
                        key: Self.gatewayConfigKey,
                        appIntentsConnectionID: connectionID,
                        nextAuditSequence: 1,
                        auditBytes: 0,
                        compactionFloor: 1,
                        configSchemaVersion: Self.gatewayConfigSchemaVersion
                    ))
                    context.insert(ConnectionRow(
                        id: connectionID,
                        displayNameRaw: Self.gatewayConnectionDisplayName,
                        enrollKindRaw: ConnectionEnrollKind.appIntents.rawValue,
                        statusRaw: ConnectionStatus.active.rawValue,
                        enrolledAt: enrolledAt,
                        revokedAt: nil,
                        configSchemaVersion: Self.gatewayConfigSchemaVersion
                    ))
                }
            } catch {
                throw HistoryFailure.persistence(.openStore)
            }

        case 1:
            try Self.validateExistingGatewayBootstrap(
                configs[0],
                in: context
            )

        default:
            throw HistoryFailure.persistence(.invariantViolation)
        }
    }

    /// The shared X.3 absence classifier. Each unfiltered one-row probe
    /// answers only whether a Gateway table contains any durable fact;
    /// startup never loads an unbounded registry or audit log. Internal so
    /// the earlier position and retention singleton classifiers can reject a
    /// post-X3 durable shape before either attempts a default-row repair.
    internal static func gatewayTablesAreEmpty(
        in context: ModelContext
    ) throws -> Bool {
        var configDescriptor = FetchDescriptor<GatewayConfigRow>()
        configDescriptor.fetchLimit = 1
        var connectionDescriptor = FetchDescriptor<ConnectionRow>()
        connectionDescriptor.fetchLimit = 1
        var grantDescriptor = FetchDescriptor<GrantRow>()
        grantDescriptor.fetchLimit = 1
        var operationDescriptor = FetchDescriptor<OperationRecordRow>()
        operationDescriptor.fetchLimit = 1
        do {
            let configs = try context.fetch(configDescriptor)
            let connections = try context.fetch(connectionDescriptor)
            let grants = try context.fetch(grantDescriptor)
            let operations = try context.fetch(operationDescriptor)
            return configs.isEmpty
                && connections.isEmpty
                && grants.isEmpty
                && operations.isEmpty
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
    }

    /// Validates the current-release exact table shape without repair.
    private static func validateExistingGatewayBootstrap(
        _ config: GatewayConfigRow,
        in context: ModelContext
    ) throws {
        guard config.key == gatewayConfigKey else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        guard config.configSchemaVersion == gatewayConfigSchemaVersion else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        guard config.nextAuditSequence == 1,
              config.auditBytes == 0,
              config.compactionFloor == 1 else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        var connectionDescriptor = FetchDescriptor<ConnectionRow>()
        connectionDescriptor.fetchLimit = 2
        let connections: [ConnectionRow]
        do {
            connections = try context.fetch(connectionDescriptor)
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
        guard connections.count == 1 else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let connection = connections[0]
        guard connection.configSchemaVersion == gatewayConfigSchemaVersion else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }

        guard let enrollKind = ConnectionEnrollKind(
            rawValue: connection.enrollKindRaw
        ), let status = ConnectionStatus(rawValue: connection.statusRaw) else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        guard connection.id == config.appIntentsConnectionID,
              enrollKind == .appIntents,
              status == .active,
              connection.revokedAt == nil else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        guard connection.displayNameRaw.utf8.count
                <= ExternalLimits.standard.maximumDisplayNameUTF8Bytes,
              connection.displayNameRaw == gatewayConnectionDisplayName else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        var grantDescriptor = FetchDescriptor<GrantRow>()
        grantDescriptor.fetchLimit = 1
        var operationDescriptor = FetchDescriptor<OperationRecordRow>()
        operationDescriptor.fetchLimit = 1
        do {
            let grants = try context.fetch(grantDescriptor)
            let operations = try context.fetch(operationDescriptor)
            guard grants.isEmpty, operations.isEmpty else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
        } catch let failure as HistoryFailure {
            throw failure
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
    }
}
