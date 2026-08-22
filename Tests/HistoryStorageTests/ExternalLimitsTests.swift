/// Fixed external-gateway admission-limit proofs.
/// Owning spec: docs/v2/V2-05-external-gateway.md §4.5.
import Testing
@testable import HistoryStorage

struct ExternalLimitsTests {
    @Test func standardProfileMatchesTheApprovedTable() {
        let limits = ExternalLimits.standard

        #expect(limits.maximumDisplayNameUTF8Bytes == 256)
        #expect(limits.maximumConnections == 500)
        #expect(limits.maximumGrantRowsPerConnection == 8)
        #expect(limits.maxAffectedItemsPerRecord == 32)
        #expect(limits.maxAuditLogSize == 64 * 1_048_576)
        #expect(limits.auditRecordAccountingOverheadBytes == 128)
        #expect(limits.maximumAuditPayloadBlobBytes == 16 * 1_024)
        #expect(limits.maxAuditAgeSeconds == 31_536_000)
        #expect(limits.compactionCadenceOps == 100)
        #expect(limits.maxAuditReadBatchSize == 500)
        #expect(limits.externalBrowseLimitRange == 1...500)
    }

    @Test func customProfileRejectsNonPositiveAndInvertedBounds() {
        #expect(makeLimits(maximumDisplayNameUTF8Bytes: 0) == nil)
        #expect(makeLimits(maximumConnections: 0) == nil)
        #expect(makeLimits(maximumGrantRowsPerConnection: 0) == nil)
        #expect(makeLimits(maxAffectedItemsPerRecord: 0) == nil)
        #expect(makeLimits(maxAuditLogSize: 0) == nil)
        #expect(makeLimits(auditRecordAccountingOverheadBytes: 0) == nil)
        #expect(makeLimits(maximumAuditPayloadBlobBytes: 0) == nil)
        #expect(makeLimits(maxAuditAgeSeconds: 0) == nil)
        #expect(makeLimits(compactionCadenceOps: 0) == nil)
        #expect(makeLimits(maxAuditReadBatchSize: 0) == nil)
        #expect(makeLimits(browseLowerBound: 2, browseUpperBound: 1) == nil)
    }

    private func makeLimits(
        maximumDisplayNameUTF8Bytes: Int = 1,
        maximumConnections: Int = 1,
        maximumGrantRowsPerConnection: Int = 1,
        maxAffectedItemsPerRecord: Int = 1,
        maxAuditLogSize: Int = 1,
        auditRecordAccountingOverheadBytes: Int = 1,
        maximumAuditPayloadBlobBytes: Int = 1,
        maxAuditAgeSeconds: Int = 1,
        compactionCadenceOps: Int = 1,
        maxAuditReadBatchSize: Int = 1,
        browseLowerBound: Int = 1,
        browseUpperBound: Int = 1
    ) -> ExternalLimits? {
        ExternalLimits(
            maximumDisplayNameUTF8Bytes: maximumDisplayNameUTF8Bytes,
            maximumConnections: maximumConnections,
            maximumGrantRowsPerConnection: maximumGrantRowsPerConnection,
            maxAffectedItemsPerRecord: maxAffectedItemsPerRecord,
            maxAuditLogSize: maxAuditLogSize,
            auditRecordAccountingOverheadBytes:
                auditRecordAccountingOverheadBytes,
            maximumAuditPayloadBlobBytes: maximumAuditPayloadBlobBytes,
            maxAuditAgeSeconds: maxAuditAgeSeconds,
            compactionCadenceOps: compactionCadenceOps,
            maxAuditReadBatchSize: maxAuditReadBatchSize,
            externalBrowseLimitLowerBound: browseLowerBound,
            externalBrowseLimitUpperBound: browseUpperBound
        )
    }
}
