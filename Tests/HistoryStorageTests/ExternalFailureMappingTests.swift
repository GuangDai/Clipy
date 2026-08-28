/// X-BEHAVIOR-1 pure failure-classification matrix.
/// Owning spec: `V2-05` §5.1–§5.3/§7.3.1.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

@Suite("External History failure mapping (X.6)")
struct ExternalFailureMappingTests {
    private let itemID = HistoryItemID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-00000000B131"
    )!)
    private let revisionID = RevisionID(rawValue: UUID(
        uuidString: "00000000-0000-0000-0000-00000000B132"
    )!)

    @Test("External transient raw values are stable and unknown values fail")
    func externalTransientRawValues() {
        #expect(ExternalTransientReason.indexRebuild.rawValue == 1)
        #expect(ExternalTransientReason.storeLocked.rawValue == 2)
        #expect(ExternalTransientReason.insufficientDiskSpace.rawValue == 3)
        #expect(ExternalTransientReason.cancelled.rawValue == 4)
        #expect(ExternalTransientReason(rawValue: 0) == nil)
        #expect(ExternalTransientReason(rawValue: 5) == nil)
    }

    @Test("Every History failure leaf is classified for all seven operations")
    func completeFailureMatrix() {
        for row in failureMatrix {
            #expect(row.expected.count == operations.count)
            for (operation, expected) in zip(operations, row.expected) {
                expectMapping(row.source, for: operation, expected: expected)
            }
        }
    }

    /// Expectation order: recent, search, details, paste payload, pin, unpin,
    /// remove. Every row is intentionally literal so a changed operation set
    /// or `HistoryFailure` leaf requires an owned fixture update.
    private var failureMatrix: [MatrixRow] {
        [
            MatrixRow(
                source: .notFound(itemID),
                expected: [
                    .invariant, .invariant, .notFound, .notFound,
                    .invariant, .notFound, .notFound,
                ]
            ),
            MatrixRow(
                source: .staleContent(
                    expected: ContentVersion(rawValue: 3),
                    current: ContentVersion(rawValue: 4)
                ),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.emptyCapture),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.excludedFromHistory),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.duplicateRepresentationType("public.text")),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.unsupportedRepresentationType("")),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.representationLimit),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.byteLimit),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.invalidTimestamp),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.incoherentRevisionDraft),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.invalidRegularExpression),
                expected: [
                    .invariant, .searchInvalid, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.invalidPageLimit),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.invalidPixelSize),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.invalidRetentionPolicy),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidInput(.invalidSearchTerm),
                expected: [
                    .invariant, .searchInvalid, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidPinnedPlacement(.targetMissing),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .history, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidPinnedPlacement(.anchorMissingOrUnpinned),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .invalidPinnedPlacement(.targetEqualsAnchor),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .revisionNotFound(revisionID),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .snapshotExpired(current: ChangePosition(rawValue: 19)),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .capacityExceeded(.retainedItems),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .capacityExceeded(.revisionCount),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .capacityExceeded(.revisionBytes),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .capacityExceeded(.copyCount),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .capacityExceeded(.thumbnailBytes),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .capacityExceeded(.coherenceToken),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .history, .history, .history,
                ]
            ),
            MatrixRow(
                source: .capacityExceeded(.storageBytes),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .temporarilyUnavailable(.factProof),
                expected: [
                    .storeLocked, .storeLocked, .storeLocked, .storeLocked,
                    .storeLocked, .storeLocked, .storeLocked,
                ]
            ),
            MatrixRow(
                source: .temporarilyUnavailable(.dedupIndexRebuild),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .temporarilyUnavailable(.insufficientDiskSpace),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .insufficientDiskSpace,
                    .insufficientDiskSpace,
                    .insufficientDiskSpace,
                ]
            ),
            MatrixRow(
                source: .temporarilyUnavailable(.searchEngineDeadline),
                expected: [
                    .invariant, .searchEngineDeadline, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .persistence(.openStore),
                expected: [
                    .invariant, .invariant, .invariant, .invariant,
                    .invariant, .invariant, .invariant,
                ]
            ),
            MatrixRow(
                source: .persistence(.corruptStoredValue),
                expected: [
                    .persistence(.corruptStoredValue),
                    .persistence(.corruptStoredValue),
                    .persistence(.corruptStoredValue),
                    .persistence(.corruptStoredValue),
                    .persistence(.corruptStoredValue),
                    .persistence(.corruptStoredValue),
                    .persistence(.corruptStoredValue),
                ]
            ),
            MatrixRow(
                source: .persistence(.invariantViolation),
                expected: [
                    .persistence(.invariantViolation),
                    .persistence(.invariantViolation),
                    .persistence(.invariantViolation),
                    .persistence(.invariantViolation),
                    .persistence(.invariantViolation),
                    .persistence(.invariantViolation),
                    .persistence(.invariantViolation),
                ]
            ),
            MatrixRow(
                source: .persistence(.transaction),
                expected: [
                    .persistence(.transaction),
                    .persistence(.transaction),
                    .persistence(.transaction),
                    .persistence(.transaction),
                    .persistence(.transaction),
                    .persistence(.transaction),
                    .persistence(.transaction),
                ]
            ),
        ]
    }

    private var operations: [ExternalHistoryOperationContext] {
        [
            .readRecent,
            .readSearch,
            .readDetails,
            .readPastePayload,
            .managePin,
            .manageUnpin,
            .manageRemove,
        ]
    }

    private func expectMapping(
        _ source: HistoryFailure,
        for operation: ExternalHistoryOperationContext,
        expected: ExpectedMapping
    ) {
        switch expected {
        case .invariant:
            expectMapping(
                source,
                for: operation,
                failure: .persistence(.invariantViolation),
                kind: .persistence
            )
        case .history:
            expectMapping(
                source,
                for: operation,
                failure: .history(source),
                kind: .history
            )
        case .notFound:
            expectMapping(
                source,
                for: operation,
                failure: .notFound(itemID),
                kind: .notFound
            )
        case .persistence(let reason):
            expectMapping(
                source,
                for: operation,
                failure: .persistence(reason),
                kind: .persistence
            )
        case .storeLocked:
            expectMapping(
                source,
                for: operation,
                failure: .temporarilyUnavailable(.storeLocked),
                kind: .temporarilyUnavailable
            )
        case .insufficientDiskSpace:
            expectMapping(
                source,
                for: operation,
                failure: .temporarilyUnavailable(.insufficientDiskSpace),
                kind: .temporarilyUnavailable
            )
        case .searchInvalid:
            expectMapping(
                source,
                for: operation,
                failure: .history(source),
                kind: .requestDenied,
                denialReason: .invalidInput
            )
        case .searchEngineDeadline:
            expectMapping(
                source,
                for: operation,
                failure: .history(source),
                kind: .temporarilyUnavailable
            )
        }
    }

    private func expectMapping(
        _ source: HistoryFailure,
        for operation: ExternalHistoryOperationContext,
        failure: ExternalFailure,
        kind: ExternalFailureKindRaw,
        denialReason: ExternalDenialReason? = nil
    ) {
        let mapped = mapExternalHistoryFailure(source, for: operation)
        #expect(mapped.failure == failure)
        #expect(mapped.auditFailureKind == kind)
        #expect(mapped.auditDenialReason == denialReason)
    }

    private struct MatrixRow {
        let source: HistoryFailure
        let expected: [ExpectedMapping]
    }

    private enum ExpectedMapping {
        case invariant
        case history
        case notFound
        case persistence(PersistenceFailure)
        case storeLocked
        case insufficientDiskSpace
        case searchInvalid
        case searchEngineDeadline
    }
}
