/// Fixed admission and resource bounds for the external-gateway substrate.
/// Owning spec: docs/v2/V2-05-external-gateway.md §4.5.
import Foundation

/// The immutable limits used by gateway schema validation and bootstrap.
///
/// These values are product bounds rather than user settings. The internal
/// initializer mirrors `HistoryLimits`: focused storage tests may construct a
/// smaller valid profile without widening the public seam.
internal struct ExternalLimits: Sendable {
    internal let maximumDisplayNameUTF8Bytes: Int
    internal let maximumConnections: Int
    internal let maximumGrantRowsPerConnection: Int
    internal let maxAffectedItemsPerRecord: Int
    internal let maxAuditLogSize: Int
    internal let auditRecordAccountingOverheadBytes: Int
    internal let maximumAuditPayloadBlobBytes: Int
    internal let maxAuditAgeSeconds: Int
    internal let compactionCadenceOps: Int
    internal let maxAuditReadBatchSize: Int
    internal let externalBrowseLimitRange: ClosedRange<Int>

    /// Rejects non-positive scalar bounds and invalid browse ranges. Validation
    /// compares values only; audit counter and byte-total arithmetic belongs to
    /// the X.4 audit append/compaction boundary and must use checked arithmetic
    /// there rather than being hidden in this value object.
    internal init?(
        maximumDisplayNameUTF8Bytes: Int,
        maximumConnections: Int,
        maximumGrantRowsPerConnection: Int,
        maxAffectedItemsPerRecord: Int,
        maxAuditLogSize: Int,
        auditRecordAccountingOverheadBytes: Int,
        maximumAuditPayloadBlobBytes: Int,
        maxAuditAgeSeconds: Int,
        compactionCadenceOps: Int,
        maxAuditReadBatchSize: Int,
        externalBrowseLimitLowerBound: Int,
        externalBrowseLimitUpperBound: Int
    ) {
        guard maximumDisplayNameUTF8Bytes >= 1,
              maximumConnections >= 1,
              maximumGrantRowsPerConnection >= 1,
              maxAffectedItemsPerRecord >= 1,
              maxAuditLogSize >= 1,
              auditRecordAccountingOverheadBytes >= 1,
              maximumAuditPayloadBlobBytes >= 1,
              maxAuditAgeSeconds >= 1,
              compactionCadenceOps >= 1,
              maxAuditReadBatchSize >= 1,
              externalBrowseLimitLowerBound >= 1,
              externalBrowseLimitLowerBound <= externalBrowseLimitUpperBound
        else { return nil }

        self.maximumDisplayNameUTF8Bytes = maximumDisplayNameUTF8Bytes
        self.maximumConnections = maximumConnections
        self.maximumGrantRowsPerConnection = maximumGrantRowsPerConnection
        self.maxAffectedItemsPerRecord = maxAffectedItemsPerRecord
        self.maxAuditLogSize = maxAuditLogSize
        self.auditRecordAccountingOverheadBytes =
            auditRecordAccountingOverheadBytes
        self.maximumAuditPayloadBlobBytes = maximumAuditPayloadBlobBytes
        self.maxAuditAgeSeconds = maxAuditAgeSeconds
        self.compactionCadenceOps = compactionCadenceOps
        self.maxAuditReadBatchSize = maxAuditReadBatchSize
        self.externalBrowseLimitRange =
            externalBrowseLimitLowerBound...externalBrowseLimitUpperBound
    }

    /// Exactly the §4.5 table values. Byte units are binary (64 MiB).
    internal static let standard: ExternalLimits = ExternalLimits(
        maximumDisplayNameUTF8Bytes: 256,
        maximumConnections: 500,
        maximumGrantRowsPerConnection: 8,
        maxAffectedItemsPerRecord: 32,
        maxAuditLogSize: 64 * 1_048_576,
        auditRecordAccountingOverheadBytes: 128,
        maximumAuditPayloadBlobBytes: 16 * 1_024,
        maxAuditAgeSeconds: 31_536_000,
        compactionCadenceOps: 100,
        maxAuditReadBatchSize: 500,
        externalBrowseLimitLowerBound: 1,
        externalBrowseLimitUpperBound: 500
    )!
}
