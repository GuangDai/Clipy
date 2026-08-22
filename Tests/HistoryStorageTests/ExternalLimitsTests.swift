/// Fixed external-gateway admission-limit proofs.
/// Owning spec: docs/v2/V2-05-external-gateway.md §4.5.
import Testing
@testable import HistoryStorage

struct ExternalLimitsTests {
    @Test func standardProfileMatchesTheApprovedTable() {
        let limits = ExternalLimits.standard

        #expect(limits.maximumDisplayNameUTF8Bytes == 256)
        #expect(limits.maxAffectedItemsPerRecord == 32)
        #expect(limits.maxAuditLogSize == 64 * 1_048_576)
        #expect(limits.maxAuditAgeSeconds == 31_536_000)
        #expect(limits.compactionCadenceOps == 100)
        #expect(limits.maxAuditReadBatchSize == 500)
        #expect(limits.externalBrowseLimitRange == 1...500)
    }

    @Test func customProfileRejectsNonPositiveAndInvertedBounds() {
        #expect(
            ExternalLimits(
                maximumDisplayNameUTF8Bytes: 0,
                maxAffectedItemsPerRecord: 1,
                maxAuditLogSize: 1,
                maxAuditAgeSeconds: 1,
                compactionCadenceOps: 1,
                maxAuditReadBatchSize: 1,
                externalBrowseLimitLowerBound: 1,
                externalBrowseLimitUpperBound: 1
            ) == nil
        )
        #expect(
            ExternalLimits(
                maximumDisplayNameUTF8Bytes: 1,
                maxAffectedItemsPerRecord: 1,
                maxAuditLogSize: 1,
                maxAuditAgeSeconds: 1,
                compactionCadenceOps: 1,
                maxAuditReadBatchSize: 1,
                externalBrowseLimitLowerBound: 2,
                externalBrowseLimitUpperBound: 1
            ) == nil
        )
    }
}
