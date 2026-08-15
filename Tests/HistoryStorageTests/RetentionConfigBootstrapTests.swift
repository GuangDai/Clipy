/// M1.3 proof (`V2-roadmap` §5 M1.3): the retention-expansion config
/// bootstrap creates/validates exactly-one `RetentionExpansionConfigRow` —
/// absent → the all-disabled v1-faithful defaults; present → the
/// fail-closed `configSchemaVersion == 1` / finiteness (DC-21) /
/// non-contradictory-combination validation (`V2-02` §3.3). Containers are
/// built directly over `Schema(versionedSchema: HistorySchemaV2.self)` (the
/// open-path wiring lands with M1.4's migration plan), and
/// `HistoryAuthority.ensureRetentionExpansionConfig(in:)` is driven via
/// @testable.
///
/// Expected values below are the `V2-02` §8.3 literals, not the
/// implementation constants: R1 `1 s ... 3,650 d` (3,650 × 86,400 s =
/// 315,360,000 s); R2 `1 ... 5,000 × 384 MiB` (5,000 × 384 × 1,048,576 =
/// 2,013,265,920,000 bytes); R3 count `1 ... 100`; R3 bytes
/// `1 ... 256 MiB` (268,435,456 bytes).
///
/// Fixture mechanics: each crafted config row is inserted WITHOUT an
/// intervening save and validated in the same context — SwiftData fetches
/// see the pending insert (CoreData `includesPendingChanges` semantics), and
/// this also keeps a `NaN` `ageMaxSeconds` testable in memory (SQLite
/// persists NaN as NULL, so a save round trip cannot carry it). The
/// absent-row test additionally re-fetches through a FRESH context to prove
/// the create's `ModelContext.transaction` actually saved.
import Foundation
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Retention config bootstrap (M1.3)")
struct RetentionConfigBootstrapTests {

    // MARK: - Fixtures

    /// A fresh in-memory container over the V2 schema with a ready context.
    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let schema = Schema(versionedSchema: HistorySchemaV2.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return (container, context)
    }

    /// One crafted config row; every default is the valid all-disabled
    /// shape (`V2-02` §3.3), and each test overrides exactly the field(s)
    /// under proof.
    private func makeConfigRow(
        agePolicyEnabled: Bool = false,
        ageMaxSeconds: Double = 0,
        storagePolicyEnabled: Bool = false,
        storageMaxBytes: Int = 0,
        revisionPolicyEnabled: Bool = false,
        revisionMaxCount: Int? = nil,
        revisionMaxBytes: Int? = nil,
        configSchemaVersion: UInt16 = 1
    ) -> RetentionExpansionConfigRow {
        RetentionExpansionConfigRow(
            key: "retention-expansion",
            agePolicyEnabled: agePolicyEnabled,
            ageMaxSeconds: ageMaxSeconds,
            storagePolicyEnabled: storagePolicyEnabled,
            storageMaxBytes: storageMaxBytes,
            revisionPolicyEnabled: revisionPolicyEnabled,
            revisionMaxCount: revisionMaxCount,
            revisionMaxBytes: revisionMaxBytes,
            configSchemaVersion: configSchemaVersion
        )
    }

    private func fetchConfigs(_ context: ModelContext) throws -> [RetentionExpansionConfigRow] {
        try context.fetch(FetchDescriptor<RetentionExpansionConfigRow>())
    }

    /// Asserts the full §3.3 all-disabled default surface against the spec
    /// literals (`V2-02` §3.3: `agePolicyEnabled == false`, etc.).
    private func assertAllDisabled(_ row: RetentionExpansionConfigRow) {
        #expect(row.key == "retention-expansion")
        #expect(row.agePolicyEnabled == false)
        #expect(row.ageMaxSeconds == 0)
        #expect(row.storagePolicyEnabled == false)
        #expect(row.storageMaxBytes == 0)
        #expect(row.revisionPolicyEnabled == false)
        #expect(row.revisionMaxCount == nil)
        #expect(row.revisionMaxBytes == nil)
        #expect(row.configSchemaVersion == 1)
    }

    // MARK: - Absent → create exactly the all-disabled row

    /// `V2-roadmap` §5 total open order step 5 / `V2-02` §3.3: an absent row
    /// (the only create-with-defaults path) creates exactly one all-disabled
    /// row with `configSchemaVersion == 1`, so a migrated store starts
    /// v1-faithful.
    @Test("absent config creates exactly one all-disabled row, durably")
    func absentConfigCreatesExactlyOneAllDisabledRow() throws {
        let (container, context) = try makeContext()

        try HistoryAuthority.ensureRetentionExpansionConfig(in: context)

        // Durable proof: the create ran in a ModelContext.transaction, so a
        // FRESH context over the same container sees the saved row.
        let freshContext = ModelContext(container)
        let rows = try fetchConfigs(freshContext)
        #expect(rows.count == 1)
        assertAllDisabled(try #require(rows.first))
    }

    // MARK: - Present and valid → unchanged

    /// A valid all-disabled row (the persisted default shape) is left
    /// untouched: no re-create, no rewrite.
    @Test("valid disabled row is unchanged")
    func validDisabledRowIsUnchanged() throws {
        let (_, context) = try makeContext()
        context.insert(makeConfigRow())

        try HistoryAuthority.ensureRetentionExpansionConfig(in: context)

        let rows = try fetchConfigs(context)
        #expect(rows.count == 1)
        assertAllDisabled(try #require(rows.first))
    }

    /// A fully-enabled row whose every value is inside the §8.3 bounds is a
    /// valid stored unit and is left untouched. Bounds-interior literals:
    /// 86,400 s (1 d); 512 MiB (536,870,912 bytes) ≤ 5,000 × 384 MiB;
    /// 20 ≤ 100 revisions; 16 MiB (16,777,216 bytes) ≤ 256 MiB.
    @Test("valid fully-enabled in-range row is unchanged")
    func validFullyEnabledRowIsUnchanged() throws {
        let (_, context) = try makeContext()
        context.insert(makeConfigRow(
            agePolicyEnabled: true,
            ageMaxSeconds: 86_400,
            storagePolicyEnabled: true,
            storageMaxBytes: 536_870_912,
            revisionPolicyEnabled: true,
            revisionMaxCount: 20,
            revisionMaxBytes: 16_777_216,
            configSchemaVersion: 1
        ))

        try HistoryAuthority.ensureRetentionExpansionConfig(in: context)

        let rows = try fetchConfigs(context)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.agePolicyEnabled == true)
        #expect(row.ageMaxSeconds == 86_400)
        #expect(row.storagePolicyEnabled == true)
        #expect(row.storageMaxBytes == 536_870_912)
        #expect(row.revisionPolicyEnabled == true)
        #expect(row.revisionMaxCount == 20)
        #expect(row.revisionMaxBytes == 16_777_216)
        #expect(row.configSchemaVersion == 1)
    }

    // MARK: - Unknown configSchemaVersion (forward-incompatible)

    /// `V2-02` §3.3: "A row with an unknown `configSchemaVersion`
    /// (forward-incompatible) ... fails closed as
    /// `.persistence(.corruptStoredValue)`" — the codec-discipline analog of
    /// an unknown blob `formatVersion` (`05` §4).
    @Test("unknown configSchemaVersion fails closed as corruptStoredValue")
    func unknownConfigSchemaVersionFailsClosed() throws {
        let (_, context) = try makeContext()
        context.insert(makeConfigRow(configSchemaVersion: 2))

        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try HistoryAuthority.ensureRetentionExpansionConfig(in: context)
        }
        // Fail closed means fail before any write: no repair row appeared.
        #expect(try fetchConfigs(context).count == 1)
    }

    // MARK: - DC-21 finiteness

    /// `V2-02` §3.3/§8.3 (DC-21): "a persisted non-finite `ageMaxSeconds` on
    /// the `RetentionExpansionConfigRow` fails closed at config load as
    /// `.persistence(.corruptStoredValue)` ... never silently treated as a
    /// disabled or infinite policy."
    @Test("non-finite ageMaxSeconds fails closed as corruptStoredValue")
    func nonFiniteAgeMaxSecondsFailsClosed() throws {
        // Both NaN (every comparison false, so range checks alone cannot
        // catch it — the explicit isFinite requirement) and +Infinity.
        for badValue in [Double.nan, Double.infinity] {
            let (_, context) = try makeContext()
            context.insert(makeConfigRow(
                agePolicyEnabled: true,
                ageMaxSeconds: badValue
            ))

            #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                try HistoryAuthority.ensureRetentionExpansionConfig(in: context)
            }
        }
    }

    // MARK: - Out-of-range / contradictory combinations

    /// Every §8.3 out-of-range or contradictory combination fails closed as
    /// `.persistence(.invariantViolation)` (`V2-02` §3.3). Invalid literals
    /// are the spec bounds ± 1, derived from §8.3, not from the
    /// implementation constants:
    ///
    /// - R1 below/above: 0.5 s and 315,360,001 s (bound: 3,650 × 86,400);
    /// - R2 below/above: 0 and 2,013,265,920,001 bytes
    ///   (bound: 5,000 × 384 × 1,048,576);
    /// - R3 count below/above: 0 and 101 (bound: 1 ... 100);
    /// - R3 bytes below/above: 0 and 268,435,457 bytes (256 × 1,048,576 + 1);
    /// - the named contradiction: `revisionPolicyEnabled` with BOTH
    ///   thresholds nil.
    @Test("out-of-range and contradictory combinations fail closed as invariantViolation")
    func outOfRangeAndContradictoryCombinationsFailClosed() throws {
        struct Shape {
            let label: String
            let row: RetentionExpansionConfigRow
        }
        let shapes: [Shape] = [
            Shape(label: "R1 below 1 s", row: makeConfigRow(
                agePolicyEnabled: true, ageMaxSeconds: 0.5
            )),
            Shape(label: "R1 above 3,650 d", row: makeConfigRow(
                agePolicyEnabled: true, ageMaxSeconds: 315_360_001
            )),
            Shape(label: "R2 below 1 byte", row: makeConfigRow(
                storagePolicyEnabled: true, storageMaxBytes: 0
            )),
            Shape(label: "R2 above 5,000 x 384 MiB", row: makeConfigRow(
                storagePolicyEnabled: true, storageMaxBytes: 2_013_265_920_001
            )),
            Shape(label: "R3 enabled with both thresholds nil", row: makeConfigRow(
                revisionPolicyEnabled: true, revisionMaxCount: nil, revisionMaxBytes: nil
            )),
            Shape(label: "R3 count below 1", row: makeConfigRow(
                revisionMaxCount: 0
            )),
            Shape(label: "R3 count above 100", row: makeConfigRow(
                revisionMaxCount: 101
            )),
            Shape(label: "R3 bytes below 1", row: makeConfigRow(
                revisionMaxBytes: 0
            )),
            Shape(label: "R3 bytes above 256 MiB", row: makeConfigRow(
                revisionMaxBytes: 268_435_457
            )),
        ]
        for shape in shapes {
            let (_, context) = try makeContext()
            context.insert(shape.row)

            do {
                try HistoryAuthority.ensureRetentionExpansionConfig(in: context)
                Issue.record("\(shape.label): expected .invariantViolation, got no error")
            } catch let failure as HistoryFailure
            where failure == .persistence(.invariantViolation) {
                // The exact typed failure for this shape.
            } catch {
                Issue.record("\(shape.label): unexpected error \(error)")
            }
        }
    }

    // MARK: - Duplicate singleton

    /// `V2-02` §3.3 mirrors the v1 singleton's exactly-one proof
    /// (`05` §13 step 4): zero or duplicate singletons are
    /// `.persistence(.invariantViolation)`; two pending inserts with the
    /// same key are visible to the fetch before any save-time unique
    /// enforcement could mask them.
    @Test("duplicate config rows fail closed as invariantViolation")
    func duplicateConfigRowsFailClosed() throws {
        let (_, context) = try makeContext()
        context.insert(makeConfigRow())
        context.insert(makeConfigRow())

        #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try HistoryAuthority.ensureRetentionExpansionConfig(in: context)
        }
    }
}
