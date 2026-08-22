/// S-1 regression proofs (docs/reviews/2026-08-20-clipy-maccy-audit/
/// 01-standards.md §S-1): a `RetainedBytesRow` carrying an IMPOSSIBLE scalar
/// (negative or over-hard-bound `canonicalBytes`/`revisionCount`/
/// `revisionBytes`, or the contradictory `revisionCount == 0` with nonzero
/// `revisionBytes`) fails closed at the scalar-projection read boundary
/// (`RetentionConfigLoading.fetchProjectedScalars`) instead of feeding
/// R2/R3 destructive planning.
///
/// Owning spec: `V2-02` §3.3b projection-coherence (a row whose scalars are
/// inconsistent "fails closed as `.persistence(.corruptStoredValue)` /
/// `.persistence(.invariantViolation)` (`05` §4/§16) — it is never silently
/// used as a stale byte fact"), §3.2 (planning treats each projected scalar
/// as authoritative — a negative `canonicalBytes` would make a positive
/// byte budget look satisfied, an impossible huge value would retire valid
/// items), `06` §2 (bounded, non-wrapping byte arithmetic; the `HistoryLimits
/// .standard` hard bounds the stamping lanes already enforce). The failure
/// vocabulary is the loader's own pre-existing one —
/// `.persistence(.invariantViolation)` — exactly as for its row-count,
/// duplicate-ID, and `bytesSchemaVersion` violations.
///
/// Every fixture crosses the public `SwiftDataHistory.perform` path with the
/// row damaged behind the Authority's back through an INDEPENDENT container
/// (the R.3 corruption-fixture stance), on all three projection consumers:
/// the R.4 capture lane (R1/R2), the R.5 revise lane (R2/R3), and the R.6
/// `.setRetentionPolicies` sweep (R1/R2/R3). The startup 1:1 check
/// deliberately reads only `itemID`/`bytesSchemaVersion` (S-1's second
/// bullet — a known, accepted open-time scope), so the corruption here is
/// introduced AFTER `open` and the proofs pin the planning-read boundary.
///
/// Exact in-range blob/projection mismatch (e.g. a plausible-but-wrong
/// `canonicalBytes` of 12 where the blob sums to 15) remains the separate
/// design limitation of the deliberate zero-decode R2 lane
/// (`RET-PLATFORM-2`) and is NOT claimed to be detected here.
import Foundation
import HistoryCore
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("RetainedBytesRow scalar validation (S-1)")
struct RetainedBytesScalarValidationTests {

    // MARK: - Fixtures

    /// The impossible-scalar matrix: one case per damaged field, negative
    /// and over-hard-bound (`06` §2 table values via `HistoryLimits
    /// .standard`), plus the one structural contradiction (an empty revision
    /// list sums to zero bytes, DC-04).
    enum ScalarCorruption: Equatable, CaseIterable {
        case negativeCanonicalBytes
        case overBoundCanonicalBytes
        case negativeRevisionCount
        case overBoundRevisionCount
        case negativeRevisionBytes
        case overBoundRevisionBytes
        case zeroCountNonzeroBytes
    }

    /// Performs one raw text capture and returns the inserted reference.
    @discardableResult
    private static func capture(
        _ text: String,
        at seconds: Double,
        source: String,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                text,
                observedAt: Date(timeIntervalSinceReferenceDate: seconds),
                source: source
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome else {
            Issue.record("S-1 setup: expected .committed with .inserted, got \(receipt)")
            throw HistoryFailure.notFound(HistoryItemID(rawValue: UUID()))
        }
        return reference
    }

    /// Damages the one projection scalar of `itemID`'s `RetainedBytesRow`
    /// behind the Authority's back through an INDEPENDENT container (the
    /// R.3 fixture stance): the row is fetched, mutated, and saved through
    /// the SAME context — a `@Model` is bound to the context that fetched
    /// it, so a mutation through another context would never persist.
    private static func corruptScalars(
        of itemID: HistoryItemID,
        corruption: ScalarCorruption,
        storeURL: URL
    ) throws {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let uuid = itemID.rawValue
        let rows = try context.fetch(FetchDescriptor<RetainedBytesRow>(
            predicate: #Predicate { row in row.itemID == uuid }
        ))
        let row = try #require(rows.first)
        switch corruption {
        case .negativeCanonicalBytes:
            row.canonicalBytes = -1
        case .overBoundCanonicalBytes:
            row.canonicalBytes = HistoryLimits.standard.maximumCaptureBytes + 1
        case .negativeRevisionCount:
            row.revisionCount = -1
        case .overBoundRevisionCount:
            row.revisionCount = HistoryLimits.standard.maximumRevisionsPerItem + 1
        case .negativeRevisionBytes:
            row.revisionBytes = -1
        case .overBoundRevisionBytes:
            row.revisionBytes = HistoryLimits.standard
                .maximumTotalRevisionBytesPerItem + 1
        case .zeroCountNonzeroBytes:
            row.revisionCount = 0
            row.revisionBytes = 1
        }
        try context.save()
    }

    /// Every `RetainedBytesRow`, over the independent assertion container.
    private static func fetchBytesRows(
        _ container: ModelContainer
    ) throws -> [RetainedBytesRow] {
        try ModelContext(container).fetch(FetchDescriptor<RetainedBytesRow>())
    }

    // MARK: - R.4 capture lane (V2-02 §4.2/§7: capture fires R1+R2)

    /// With R2 active, the capture expansion plans over the projected
    /// scalars as AUTHORITATIVE byte facts (§3.2): an impossible scalar must
    /// fail the commit closed BEFORE the R2 feasibility/victim arithmetic —
    /// never clamp and never retire or under-retain on a corrupt fact. The
    /// failed commit lands nothing (§2.2 atomicity): the probe item is not
    /// inserted and the corrupted item is not retired.
    @Test(
        "capture planning fails closed on an impossible projected scalar (S-1)",
        arguments: ScalarCorruption.allCases
    )
    func captureFailsClosedOnImpossibleScalar(
        corruption: ScalarCorruption
    ) async throws {
        let storeURL = WSSupport.tempStoreURL("s1-capture-\(corruption)")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let existing = try await Self.capture(
            "s1 retained item",
            at: 700_200_000,
            source: "com.example.s1.capture",
            in: history
        )

        // R2 active so the capture lane takes the expansion route and loads
        // the scalar projection (§7 trigger gate; 1 GiB is inside the §8.3
        // `1 ... 5,000 × 384 MiB` bound and far above any fixture total).
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            storage: StorageRetention(maxTotalBytes: 1_073_741_824)
        )
        try Self.corruptScalars(
            of: existing.id,
            corruption: corruption,
            storeURL: storeURL
        )

        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            _ = try await Self.capture(
                "s1 capture probe",
                at: 700_200_100,
                source: "com.example.s1.capture",
                in: history
            )
        }

        // Nothing landed: the store still holds exactly the one pre-corruption
        // item, with its (corrupted) projection row untouched.
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        #expect(try WSSupport.fetchRows(container).map(\.id) == [existing.id.rawValue])
        #expect(try Self.fetchBytesRows(container).count == 1)
    }

    // MARK: - R.6 sweep lane (V2-02 §4.4: .setRetentionPolicies fires R1/R2/R3)

    /// The sweep's R3 exceedance detection and R2 totals both read the
    /// scalar projection (§3.3b, `RET-PERF-2`): an impossible scalar must
    /// fail the action closed, and a failed sweep commits nothing
    /// (`RET-SECURITY-1`) — the persisted config stays at its all-disabled
    /// bootstrap shape and no item is retired or pruned.
    @Test(
        "policy sweep fails closed on an impossible projected scalar (S-1)",
        arguments: ScalarCorruption.allCases
    )
    func sweepFailsClosedOnImpossibleScalar(
        corruption: ScalarCorruption
    ) async throws {
        let storeURL = WSSupport.tempStoreURL("s1-sweep-\(corruption)")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let existing = try await Self.capture(
            "s1 sweep item",
            at: 700_210_000,
            source: "com.example.s1.sweep",
            in: history
        )
        try Self.corruptScalars(
            of: existing.id,
            corruption: corruption,
            storeURL: storeURL
        )

        // Storage + revision thresholds both active so the sweep would run
        // the R3 exceedance detection and the R2 totals over the corrupted
        // scalars if the boundary let them through.
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            _ = try await history.perform(.setRetentionPolicies(
                HistoryRetentionPolicies(
                    age: nil,
                    storage: StorageRetention(maxTotalBytes: 1_073_741_824),
                    revisions: RevisionRetention(
                        maxRevisionsPerItem: 100,
                        maxRevisionBytesPerItem: nil
                    )
                )
            ))
        }

        // RET-SECURITY-1: a vetoed/failed sweep commits nothing — the item
        // survives and the config singleton is still the all-disabled
        // bootstrap shape (the policy mutation never persisted).
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        #expect(try WSSupport.fetchRows(container).map(\.id) == [existing.id.rawValue])
        let configRows = try ModelContext(container).fetch(
            FetchDescriptor<RetentionExpansionConfigRow>()
        )
        let config = try #require(configRows.first)
        #expect(config.storagePolicyEnabled == false)
        #expect(config.revisionPolicyEnabled == false)
    }

    // MARK: - R.5 revise lane (V2-02 §4.3/§7: revise fires R2+R3)

    /// The revise lane's phase-2 expansion reads every OTHER item's scalars
    /// from the projection (the revised item's own post-append scalars are
    /// computed in memory, §3.2): a corrupted NON-revised item's impossible
    /// scalar must fail the whole revise closed (§2.2 — the append does not
    /// land), never silently enter the R2 projected inventory.
    @Test(
        "revise planning fails closed on a non-revised item's impossible scalar (S-1)",
        arguments: ScalarCorruption.allCases
    )
    func reviseFailsClosedOnImpossibleScalar(
        corruption: ScalarCorruption
    ) async throws {
        let storeURL = WSSupport.tempStoreURL("s1-revise-\(corruption)")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let target = try await Self.capture(
            "s1 revise target",
            at: 700_220_000,
            source: "com.example.s1.revise",
            in: history
        )
        let victim = try await Self.capture(
            "s1 revise victim",
            at: 700_220_100,
            source: "com.example.s1.revise",
            in: history
        )

        // R2 active: the revise lane (R2+R3, §7) then plans over the
        // projected inventory in phase 2 (`RetentionReviseComposition`).
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            storage: StorageRetention(maxTotalBytes: 1_073_741_824)
        )
        // The corruption sits on the NON-revised item — the exact item whose
        // scalars the planning path reads from the projection row.
        try Self.corruptScalars(
            of: victim.id,
            corruption: corruption,
            storeURL: storeURL
        )

        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            _ = try await history.perform(.revise(RevisionRequest(
                itemID: target.id,
                expected: ContentVersion(rawValue: 1),
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(
                        typeIdentifier: "public.utf8-plain-text",
                        action: .replace(bytes: Data("s1 revised bytes".utf8))
                    ),
                ]))
            )))
        }

        // The revise committed nothing (§2.2): both items survive and the
        // target's content version is still the insert's version 1.
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let rows = try WSSupport.fetchRows(container)
        #expect(rows.count == 2)
        let targetRow = try #require(
            rows.first { $0.id == target.id.rawValue }
        )
        #expect(targetRow.contentVersionRaw == 1)
    }
}
