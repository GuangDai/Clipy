/// V2-09: negative persisted counts fail SQLite constraints; impossible
/// bounded/relational item facts fail the purpose-specific metadata read.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct RetainedBytesScalarValidationTests {
    enum Damage: CaseIterable, Sendable {
        case negativeCanonical, negativeCount, negativeRevisionBytes
        case zeroCanonical, overCanonical, overCount, overRevisionBytes
        case zeroCountWithBytes, positiveCountWithoutBytes, fewerBytesThanRevisions

        var counts: RetainedBytesTestSupport.Counts {
            switch self {
            case .negativeCanonical: .init(canonical: -1, revisions: 0, revisionBytes: 0)
            case .negativeCount: .init(canonical: 5, revisions: -1, revisionBytes: 0)
            case .negativeRevisionBytes: .init(canonical: 5, revisions: 0, revisionBytes: -1)
            case .zeroCanonical: .init(canonical: 0, revisions: 0, revisionBytes: 0)
            case .overCanonical:
                .init(canonical: HistoryLimits.standard.maximumCaptureBytes + 1, revisions: 0, revisionBytes: 0)
            case .overCount:
                .init(canonical: 5, revisions: HistoryLimits.standard.maximumRevisionsPerItem + 1,
                      revisionBytes: HistoryLimits.standard.maximumRevisionsPerItem + 1)
            case .overRevisionBytes:
                .init(canonical: 5, revisions: 1,
                      revisionBytes: HistoryLimits.standard.maximumTotalRevisionBytesPerItem + 1)
            case .zeroCountWithBytes: .init(canonical: 5, revisions: 0, revisionBytes: 1)
            case .positiveCountWithoutBytes: .init(canonical: 5, revisions: 1, revisionBytes: 0)
            case .fewerBytesThanRevisions: .init(canonical: 5, revisions: 2, revisionBytes: 1)
            }
        }

        var violatesSQLConstraint: Bool {
            switch self {
            case .negativeCanonical, .negativeCount, .negativeRevisionBytes: true
            default: false
            }
        }
    }

    @Test(arguments: Damage.allCases)
    func invalidItemAccountingIsRejectedWithoutRepair(_ damage: Damage) async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let item = try await RetainedBytesTestSupport.capture("alpha", in: history)
        let before = try await history.usage()
        if damage.violatesSQLConstraint {
            do {
                try await RetainedBytesTestSupport.replaceCounts(item.id, with: damage.counts, in: history)
                Issue.record("SQLite must reject negative byte/count columns")
            } catch let failure as SQLiteFailure {
                #expect(failure.isConstraint)
            }
            #expect(try await RetainedBytesTestSupport.counts(item.id, in: history)
                == RetainedBytesTestSupport.Counts(canonical: 5, revisions: 0, revisionBytes: 0))
            #expect(try await history.pastePayload(for: item.id).representations.first?.bytes == Data("alpha".utf8))
        } else {
            try await RetainedBytesTestSupport.replaceCounts(item.id, with: damage.counts, in: history)
            await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                try await history.details(for: item.id)
            }
            #expect(try await RetainedBytesTestSupport.counts(item.id, in: history) == damage.counts)
        }
        // Usage reads committed aggregates independently of per-item content.
        #expect(try await history.usage() == before)
    }
}
