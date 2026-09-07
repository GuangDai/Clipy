/// X.3 Gateway bootstrap (`V2-roadmap` §10 X.3; `V2-05` §4.6).
///
/// X.3's absent-store path remains the deny-by-default bootstrap. Existing X.4
/// stores delegate bounded connection/grant validation to
/// `GatewayAdministration` and retained audit validation to
/// `GatewayAuditStore`. No hash or audit-chain validation belongs to this
/// schema.
import Foundation
import HistoryCore

extension HistoryAuthority {
    internal static let gatewayConfigKey = "external-gateway"
    internal static let gatewayConfigSchemaVersion: UInt16 = 1
    internal static let gatewayConnectionDisplayName =
        "Siri / Shortcuts / Spotlight"

    /// Bootstraps or validates the complete X.3 Gateway table shape.
    ///
    /// Absence is a fresh-store create path only at position zero when retained history and
    /// its byte-accounting rows, all Gateway tables, and HCR tables are empty. The config
    /// singleton and its matching
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
    internal func ensureGatewayBootstrap(
        in context: SQLiteDatabase
    ) throws -> ExternalConnectionID {
        var configs: [GatewayConfigRow] = []
        do {
            let statement = try context.prepare("SELECT \(GatewayConfigRow.columns) FROM gateway_config LIMIT 2")
            while try statement.step() { configs.append(try GatewayConfigRow(statement: statement)) }
        } catch let failure as HistoryFailure {
            throw failure
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }

        switch configs.count {
        case 0:
            let historyIsEmpty: Bool
            do {
                let state = try context.prepare("SELECT key, changePosition, retainedItemCount, canonicalBytes, revisionBytes FROM history_state LIMIT 2")
                let hasState = try state.step()
                if hasState {
                    let emptyState = try state.text(at: 0) == "retained-history"
                        && sqliteUInt64(state.blob(at: 1)) == 0
                        && state.integer(at: 2) == 0
                        && state.integer(at: 3) == 0
                        && state.integer(at: 4) == 0
                    let extraState = try state.step()
                    let item = try context.prepare("SELECT 1 FROM history_items LIMIT 1")
                    historyIsEmpty = try emptyState && !extraState && !item.step()
                } else {
                    historyIsEmpty = false
                }
            } catch {
                throw HistoryFailure.persistence(.openStore)
            }
            guard historyIsEmpty,
                  try Self.gatewayTablesAreEmpty(in: context),
                  try HCRBootstrap.tablesAreEmpty(in: context) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            let connectionID = gatewayConnectionIDSource()
            let enrolledAt = storageClock.now()
            do {
                try context.execute(
                    "INSERT INTO gateway_config (key, appIntentsConnectionID, nextAuditSequence, auditBytes, compactionFloor, configSchemaVersion) VALUES (?, ?, ?, ?, ?, ?)",
                    bindings: [
                        .text(Self.gatewayConfigKey), .text(connectionID.uuidString),
                        .blob(sqliteUInt64(1)), .blob(sqliteUInt64(0)), .blob(sqliteUInt64(1)),
                        .integer(Int64(Self.gatewayConfigSchemaVersion))
                    ]
                )
                try context.execute(
                    "INSERT INTO connections (id, displayNameRaw, enrollKindRaw, statusRaw, enrolledAt, revokedAt, configSchemaVersion) VALUES (?, ?, ?, ?, ?, NULL, ?)",
                    bindings: [
                        .text(connectionID.uuidString), .text(Self.gatewayConnectionDisplayName),
                        .integer(Int64(ConnectionEnrollKind.appIntents.rawValue)),
                        .integer(Int64(ConnectionStatus.active.rawValue)),
                        .real(enrolledAt.timeIntervalSinceReferenceDate),
                        .integer(Int64(Self.gatewayConfigSchemaVersion))
                    ]
                )
            } catch {
                throw HistoryFailure.persistence(.openStore)
            }
            return ExternalConnectionID(rawValue: connectionID)

        case 1:
            try Self.validateExistingGatewayBootstrap(
                configs[0],
                in: context
            )
            return ExternalConnectionID(
                rawValue: configs[0].appIntentsConnectionID
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
        in context: SQLiteDatabase
    ) throws -> Bool {
        do {
            let statement = try context.prepare("""
                SELECT EXISTS(SELECT 1 FROM gateway_config)
                    OR EXISTS(SELECT 1 FROM connections)
                    OR EXISTS(SELECT 1 FROM grants)
                    OR EXISTS(SELECT 1 FROM operation_records)
                """)
            guard try statement.step() else { throw HistoryFailure.persistence(.invariantViolation) }
            return try statement.integer(at: 0) == 0
        } catch let failure as HistoryFailure {
            throw failure
        } catch {
            throw HistoryFailure.persistence(.openStore)
        }
    }

    /// Validates the current-release exact table shape without repair.
    private static func validateExistingGatewayBootstrap(
        _ config: GatewayConfigRow,
        in context: SQLiteDatabase
    ) throws {
        guard config.key == gatewayConfigKey else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        guard config.configSchemaVersion == gatewayConfigSchemaVersion else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        _ = try GatewayAdministration.loadCurrentState(
            appIntentsConnectionID: config.appIntentsConnectionID,
            in: context
        )
        try GatewayAuditStore.validateRetainedState(
            config: config,
            in: context
        )
    }
}
