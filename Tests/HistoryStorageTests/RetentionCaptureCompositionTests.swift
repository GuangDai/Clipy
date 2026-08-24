/// R.4 — capture-composition proofs (`V2-roadmap` §6 R.4 "Capture
/// composition": "Run v1 count planning first; when R1/R2 is active, plan
/// over projected post-primary/post-count state, protect
/// primary/pinned/count victims, and commit one merged plan/position.
/// Coalesce uses the winner's stored bytes"; exit fixtures: count+age+byte
/// composition, pinned-over-budget hard failure, one-position, and
/// disabled-public-semantics proofs).
///
/// Owning spec: `V2-02` §4.1 (composition principle), §4.2 (the capture
/// pseudocode: v1 plan first, projected post-primary post-count inventory,
/// `protected` = pinned ∪ {primary} ∪ count victims, `now` = `observedAt`,
/// merge with unchanged outcome), §3.2 (the insert/coalesce lanes: in-memory
/// postings for the new primary, the winner's STORED scalars on coalesce),
/// §7 (trigger matrix: capture fires R1+R2 ONLY — an R3-only config takes
/// the v1 route with no expansion load), §8.3 (pinned + primary bytes >
/// `maxTotalBytes` → `.capacityExceeded(.storageBytes)` at capture,
/// atomically), §11 D24(a)/(b)/(c) (single commit, victim safety, the
/// byte-budget failure producer).
///
/// Product-composition fixtures cross the public `SwiftDataHistory.perform` /
/// real `HistoryAuthority.commitCapture` path. The DEC-CAPTURE-CLOCK skew
/// discriminator directly constructs the same real Authority solely to
/// inject a fixed `StorageClock`, the internal §6.4 test seam, and prove the
/// capture lane does not consume it. Fixtures seed policies by writing the
/// `RetentionExpansionConfigRow` through an INDEPENDENT container
/// (`WSSupport.seedRetentionConfig` — behind the Authority's back, the R.3
/// corruption-fixture stance, because the production `.setRetentionPolicies`
/// writer is the R.6 slice), and asserts rows/position/projection through
/// that same independent container.
///
/// Hand-worked fixture values (single-representation ASCII text captures:
/// one `public.utf8-plain-text` representation whose `canonicalBytes` is the
/// UTF-8 length of the text; times are `timeIntervalSinceReferenceDate`
/// seconds):
/// - "r4 count victim x" — 17 bytes (2+1+5+1+6+1+1);
/// - "r4 age victim yy" — 16 bytes (2+1+3+1+6+1+2);
/// - "r4 byte victim zzz" — 18 bytes (2+1+4+1+6+1+3);
/// - "r4 survivor wwww" — 16 bytes (2+1+8+1+4);
/// - "r4 primary payload" — 18 bytes (2+1+7+1+7);
/// - "r4 age-only victim aa" — 21 bytes (2+1+8+1+6+1+2);
/// - "r4 age-only keeper bbb" — 22 bytes (2+1+8+1+6+1+3);
/// - 30/10/20/25-char single-letter strings — 30/10/20/25 bytes;
/// - "r4 coalesce winner base" — 23 bytes plain; + a 16-byte `public.html`
///   extra representation → 39 canonical bytes for the rich winner;
/// - zero-decode fixture — B = 10, A = 10 + [5] = 15 (the corrupted
///   non-primary), P = 20, under `maxTotalBytes = 35`: 10 + 15 + 20 = 45 >
///   35 retires B (the oldest) to exactly 35; without A's scalars the
///   projected total would be 30 ≤ 35 and nothing would retire.
///
/// RET-PLATFORM-2 note (zero blob decodes on the planning path): the repo's
/// probe seams (`SearchDebugProbe`, `StorageLifecycleDebugProbe`) trace
/// search/lifecycle phases, not codec invocations — the codecs carry no
/// decode counter — so the zero-decode property is NOT asserted by
/// instrumentation here. It is proven BEHAVIORALLY by
/// `capturePlanningNeverDecodesNonPrimaryRevisionBlob` (the mirror of the
/// R.6 sweep's corrupted-blob survivor fixture): with R2 active, a
/// NON-primary item's corrupted `revisionStateBlob` that any planning-path
/// decode would surface as `.persistence(.corruptStoredValue)` instead
/// emerges byte-identical from a successful commit, while the retirement
/// arithmetic proves that item's stored scalars were planned over. That
/// fixture plus the structural guarantee — the planning path fetches
/// `RetainedBytesRow` scalar columns only
/// (`RetentionConfigLoading.fetchProjectedScalars`) and never touches the
/// `.externalStorage` blob columns — carry the `V2-02` §3.2/Record 3
/// `RET-PLATFORM-2`/`RET-PERF-3` claim.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Retention capture composition (R.4)")
struct RetentionCaptureCompositionTests {

    // MARK: - Fixtures

    /// A deliberately distinguishable Storage-owned time witness. Capture
    /// uses this for stamped Storage timestamps, but DEC-CAPTURE-CLOCK keeps
    /// R1 selection on the capture's finite `observedAt` fact.
    private struct FixedCaptureClock: StorageClock {
        let fixed: Date
        func now() -> Date { fixed }
    }

    /// Starts the real single-writer Authority with the fixed internal clock;
    /// no fake persistence writer or second capture implementation is used.
    private static func makeCaptureAuthority(
        storeURL: URL,
        storageNow: Date
    ) async throws -> HistoryAuthority {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let authority = HistoryAuthority(
            container: container,
            storageClock: FixedCaptureClock(fixed: storageNow)
        )
        try await authority.performStartup(initialMaximumUnpinnedItems: 200)
        return authority
    }

    /// Performs one prepared capture through the real Authority so the clock
    /// discriminator exercises preparation, facts, Domain planning, stamping,
    /// transaction, index delta, and publication in their production order.
    @discardableResult
    private static func authorityCapture(
        _ text: String,
        at seconds: Double,
        in authority: HistoryAuthority
    ) async throws -> HistoryItemReference {
        let prepared = try await IngestPreparationActor().prepare(
            WSSupport.textCapture(
                text,
                observedAt: Date(timeIntervalSinceReferenceDate: seconds),
                source: "com.example.r4.clock"
            )
        )
        let receipt = try await authority.commitCapture(prepared)
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome else {
            Issue.record(
                "R.4 clock setup: expected .committed with .inserted, got \(receipt)"
            )
            throw HistoryFailure.notFound(HistoryItemID(rawValue: UUID()))
        }
        return reference
    }

    /// Performs one raw text capture and returns the inserted reference.
    @discardableResult
    private static func capture(
        _ text: String,
        at seconds: Double,
        source: String,
        in history: SwiftDataHistory,
        extra: [(typeIdentifier: String, bytes: [UInt8])] = []
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                text,
                observedAt: Date(timeIntervalSinceReferenceDate: seconds),
                source: source,
                extra: extra
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .inserted(reference) = commit.outcome else {
            Issue.record("R.4 setup: expected .committed with .inserted, got \(receipt)")
            throw HistoryFailure.notFound(HistoryItemID(rawValue: UUID()))
        }
        return reference
    }

    /// The retained row IDs, deterministically ordered.
    private static func retainedIDs(
        _ container: ModelContainer
    ) throws -> [HistoryItemID] {
        try WSSupport.fetchRows(container)
            .map { HistoryItemID(rawValue: $0.id) }
    }

    /// Performs one public byte-changing `.replace` revision for the single
    /// `public.utf8-plain-text` representation, OCC-tokened at `expected`
    /// (the zero-decode fixture's lineage-growing seed; payloads are fixed
    /// `"r"`-runs, which never equal the seeded canonicals, so D4's
    /// `.unchanged` trap cannot fire).
    @discardableResult
    private static func revise(
        _ itemID: HistoryItemID,
        expected: Int,
        bytes: Int,
        in history: SwiftDataHistory
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.revise(
            RevisionRequest(
                itemID: itemID,
                expected: ContentVersion(rawValue: UInt64(expected)),
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(
                        typeIdentifier: "public.utf8-plain-text",
                        action: .replace(
                            bytes: Data(String(repeating: "r", count: bytes).utf8)
                        )
                    ),
                ]))
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .revised(reference) = commit.outcome else {
            Issue.record("R.4 setup: expected .committed with .revised, got \(receipt)")
            throw HistoryFailure.notFound(itemID)
        }
        return reference
    }

    /// Every `RetainedBytesRow`, deterministically ordered by item ID.
    private static func fetchBytesRows(
        _ container: ModelContainer
    ) throws -> [RetainedBytesRow] {
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<RetainedBytesRow>())
        return rows.sorted { $0.itemID.uuidString < $1.itemID.uuidString }
    }

    /// The unique projection row for `itemID`, or `nil` (0 or 1 rows; 2+
    /// fails the fixture loudly — the 1:1 law is a precondition here).
    private static func fetchBytesRow(
        for itemID: HistoryItemID,
        in container: ModelContainer
    ) throws -> RetainedBytesRow? {
        let context = ModelContext(container)
        let uuid = itemID.rawValue
        var descriptor = FetchDescriptor<RetainedBytesRow>(
            predicate: #Predicate { row in row.itemID == uuid }
        )
        descriptor.fetchLimit = 2
        let rows = try context.fetch(descriptor)
        precondition(
            rows.count <= 1,
            "RetainedBytesRow 1:1 law violated in fixture: \(rows.count) rows"
        )
        return rows.first
    }

    // MARK: - Count + age + byte composition (V2-02 §4.2)

    /// One capture commits v1-count, R1, and R2 victims together: with
    /// `maximumUnpinnedItems = 4`, four seeded items
    /// X(17 B, t=…000) / Y(16 B, t=…050) / Z(18 B, t=…200) / W(16 B, t=…300)
    /// and policies R1 `maxAge = 300 s` + R2 `maxTotalBytes = 34`, the final
    /// insert of P(18 B, t=…400) composes:
    /// - v1 count: 4 unpinned + 1 insert = 5 > 4 → retire the oldest, X;
    /// - projected inventory (X EXCLUDED): Y(16, t=…050), Z(18, t=…200),
    ///   W(16, t=…300), P(18, t=…400); cutoff = 400 − 300 = …100 → R1
    ///   retires Y (…050 < …100; X is excluded AND protected, D14);
    /// - R2 over the post-R1 inventory: 18+16+18 = 52 > 34 → retire the
    ///   oldest eligible, Z(18) → 16+18 = 34 ≤ 34 → stop (never further);
    /// - survivors W and P; ONE position advance (4 → 5) for the merged
    ///   commit; receipt outcome still `.inserted` (§4.2 "outcome =
    ///   v1Plan.outcome"); and the retired items' signature postings are
    ///   gone from the index — a later re-capture of X's content inserts,
    ///   never coalesces (§4.2: index delta = v1 delta + retirements).
    @Test("count+age+byte composition retires all three victims in one commit")
    func countAgeByteCompositionRetiresAllVictimsInOneCommit() async throws {
        let storeURL = WSSupport.tempStoreURL("r4-composition")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL, maximumUnpinned: 4)

        // Seeding captures run under the all-disabled default config — the
        // exact v1 route — so the store reaches 4 unpinned items untouched.
        let x = try await Self.capture(
            "r4 count victim x", at: 700_200_000, source: "com.example.r4.mix",
            in: history
        )
        let y = try await Self.capture(
            "r4 age victim yy", at: 700_200_050, source: "com.example.r4.mix",
            in: history
        )
        let z = try await Self.capture(
            "r4 byte victim zzz", at: 700_200_200, source: "com.example.r4.mix",
            in: history
        )
        let w = try await Self.capture(
            "r4 survivor wwww", at: 700_200_300, source: "com.example.r4.mix",
            in: history
        )

        // Policies land only now (the R.6 writer does not exist yet; the
        // capture lane re-reads the singleton inside every capture).
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            age: AgeRetention(maxAge: 300),
            storage: StorageRetention(maxTotalBytes: 34)
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let positionBefore = try WSSupport.fetchPosition(container).rawValue
        #expect(positionBefore == 4)

        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                "r4 primary payload",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_200_400),
                source: "com.example.r4.mix"
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .inserted(primary) = commit.outcome else {
            Issue.record("R.4: expected .committed with .inserted, got \(receipt)")
            return
        }
        // D6/D24(a): ONE position advance for the merged plan — three
        // retirements plus the insert, one ChangePosition.
        #expect(commit.position.rawValue == positionBefore + 1)

        // D24(b) victim safety + §4.1 non-interference: exactly W and the
        // primary survive; the count victim (X), the R1 victim (Y), and the
        // R2 victim (Z) are all gone, and the projection rows went with
        // their items (R.3 delete extension).
        let survivors = Set(try Self.retainedIDs(container))
        #expect(survivors == Set([w.id, primary.id]))
        #expect(!survivors.contains(x.id))
        #expect(!survivors.contains(y.id))
        #expect(!survivors.contains(z.id))
        #expect(try Self.fetchBytesRows(container).count == 2)
        #expect(try WSSupport.fetchPosition(container).rawValue == positionBefore + 1)

        // The index no longer finds the retired items' signatures: disable
        // the policies (isolating this clause from any new retirement) and
        // re-capture X's exact content — it INSERTS, because X's postings
        // left the index with the same-commit delta.
        try WSSupport.seedRetentionConfig(storeURL: storeURL)
        let reinsert = try await history.perform(.capture(
            WSSupport.textCapture(
                "r4 count victim x",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_200_500),
                source: "com.example.r4.mix"
            )
        ))
        guard case let .committed(reCommit) = reinsert,
              case .inserted = reCommit.outcome else {
            Issue.record("R.4: expected the re-capture of retired content to .inserted, got \(reinsert)")
            return
        }
    }

    // MARK: - R1-only minimal fixture (V2-02 §4.2 R1 bullet)

    /// Age fires alone: A(21 B, t=…000) is older than the strict cutoff
    /// (now − 100 s = …300) while B(22 B, t=…300) sits exactly ON it — the
    /// comparison is strict, so B survives (RET-SELECT-1(a)) — and the
    /// insert P(22 B, t=…400) retires only A.
    @Test("R1-only capture retires the aged item, boundary-exact survivor kept")
    func r1OnlyRetiresAgedItem() async throws {
        let storeURL = WSSupport.tempStoreURL("r4-r1-only")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let a = try await Self.capture(
            "r4 age-only victim aa", at: 700_300_000, source: "com.example.r4.r1",
            in: history
        )
        let b = try await Self.capture(
            "r4 age-only keeper bbb", at: 700_300_300, source: "com.example.r4.r1",
            in: history
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            age: AgeRetention(maxAge: 100)
        )

        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                "r4 age-only primary pp",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_300_400),
                source: "com.example.r4.r1"
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .inserted(primary) = commit.outcome else {
            Issue.record("R.4: expected .committed with .inserted, got \(receipt)")
            return
        }

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let survivors = Set(try Self.retainedIDs(container))
        #expect(survivors == Set([b.id, primary.id]))
        #expect(!survivors.contains(a.id))
    }

    /// DEC-CAPTURE-CLOCK / DATA-5a discriminator. The Authority's fixed clock
    /// is t=10,000 and R1 maxAge is 100. A past-skew capture at t=9,800 uses
    /// cutoff 9,700 and therefore keeps a row exactly on that boundary; if
    /// Storage admitted time controlled R1, cutoff 9,900 would retire it.
    /// A later future-skew capture at t=10,200 uses cutoff 10,100 and retires
    /// every prior unpinned row; if Storage time controlled R1, the row at
    /// t=9,900 would remain on the strict boundary. Both halves therefore
    /// distinguish the accepted observedAt rule from the rejected alternative.
    @Test("capture R1 uses finite observedAt under past and future clock skew")
    func r1CaptureUsesObservedAtRatherThanStorageClock() async throws {
        let storeURL = WSSupport.tempStoreURL("r4-r1-capture-clock-skew")
        defer { WSSupport.removeStore(storeURL) }
        let storageNow = Date(timeIntervalSinceReferenceDate: 10_000)
        let authority = try await Self.makeCaptureAuthority(
            storeURL: storeURL,
            storageNow: storageNow
        )

        let boundary = try await Self.authorityCapture(
            "r4 clock boundary", at: 9_700, in: authority
        )
        let newer = try await Self.authorityCapture(
            "r4 clock newer", at: 9_900, in: authority
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            age: AgeRetention(maxAge: 100)
        )

        let pastPrimary = try await Self.authorityCapture(
            "r4 clock past primary", at: 9_800, in: authority
        )
        let verification = try WSSupport.makeContainer(storeURL: storeURL)
        #expect(
            Set(try Self.retainedIDs(verification))
                == Set([boundary.id, newer.id, pastPrimary.id])
        )

        let futurePrimary = try await Self.authorityCapture(
            "r4 clock future primary", at: 10_200, in: authority
        )
        #expect(Set(try Self.retainedIDs(verification)) == Set([futurePrimary.id]))

        // The same four commits stamp their HCR facts from StorageClock,
        // proving observedAt controls R1 without taking ownership of
        // Storage-minted timestamps.
        let journalContext = ModelContext(verification)
        let journalRows = try journalContext.fetch(
            FetchDescriptor<HistoryChangeRecordRow>()
        )
        #expect(journalRows.count == 4)
        #expect(journalRows.allSatisfy { $0.createdAt == storageNow })
    }

    // MARK: - R2-only minimal fixture (V2-02 §4.2 R2 bullet)

    /// Bytes fire alone: A(30 B, t=…000) + B(10 B, t=…100) + the insert
    /// P(20 B, t=…200) project 60 retained bytes against
    /// `maxTotalBytes = 45` → R2 retires only the oldest eligible, A(30),
    /// restoring 60 − 30 = 30 ≤ 45 exactly (RET-SELECT-1(b): never further).
    @Test("R2-only capture retires oldest until budget restored, never further")
    func r2OnlyRetiresUntilBudgetRestored() async throws {
        let storeURL = WSSupport.tempStoreURL("r4-r2-only")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let a = try await Self.capture(
            String(repeating: "a", count: 30), at: 700_400_000, source: "com.example.r4.r2",
            in: history
        )
        let b = try await Self.capture(
            String(repeating: "b", count: 10), at: 700_400_100, source: "com.example.r4.r2",
            in: history
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            storage: StorageRetention(maxTotalBytes: 45)
        )

        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                String(repeating: "p", count: 20),
                observedAt: Date(timeIntervalSinceReferenceDate: 700_400_200),
                source: "com.example.r4.r2"
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .inserted(primary) = commit.outcome else {
            Issue.record("R.4: expected .committed with .inserted, got \(receipt)")
            return
        }

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let survivors = Set(try Self.retainedIDs(container))
        #expect(survivors == Set([b.id, primary.id]))
        #expect(!survivors.contains(a.id))
    }

    // MARK: - Pinned-over-budget hard failure (V2-02 §8.3, D24(c))

    /// Two pinned 30-byte items (irreducible, D13) plus a 20-byte primary
    /// exceed `maxTotalBytes = 50` (60 + 20 = 80 > 50): the capture fails
    /// `.capacityExceeded(.storageBytes)` BEFORE anything is stamped or
    /// transacted — atomically. The store is unchanged: the same singleton
    /// position (4: two captures + two pins), the same two rows, the same
    /// two projection rows, and no projection row for the rejected primary.
    @Test("pinned+primary over budget fails capacityExceeded(storageBytes) atomically")
    func pinnedOverBudgetFailsClosedAtomically() async throws {
        let storeURL = WSSupport.tempStoreURL("r4-pinned-over-budget")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let heavy1 = try await Self.capture(
            String(repeating: "h", count: 30), at: 700_500_000, source: "com.example.r4.pin",
            in: history
        )
        let heavy2 = try await Self.capture(
            String(repeating: "i", count: 30), at: 700_500_050, source: "com.example.r4.pin",
            in: history
        )
        // Pin mutations do not trigger V2 expansion (V2-02 §7).
        let pin1 = try await history.perform(.placePinned(heavy1.id, at: .last))
        guard case .committed = pin1 else {
            Issue.record("R.4 setup: expected the first pin to commit, got \(pin1)")
            return
        }
        let pin2 = try await history.perform(.placePinned(heavy2.id, at: .last))
        guard case .committed = pin2 else {
            Issue.record("R.4 setup: expected the second pin to commit, got \(pin2)")
            return
        }
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            storage: StorageRetention(maxTotalBytes: 50)
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let positionBefore = try WSSupport.fetchPosition(container).rawValue
        #expect(positionBefore == 4)

        await #expect(throws: HistoryFailure.capacityExceeded(.storageBytes)) {
            _ = try await history.perform(.capture(
                WSSupport.textCapture(
                    String(repeating: "p", count: 20),
                    observedAt: Date(timeIntervalSinceReferenceDate: 700_500_200),
                    source: "com.example.r4.pin"
                )
            ))
        }

        // Atomicity: nothing landed — same position, same rows, same
        // projection rows (no row exists for the rejected primary).
        #expect(try WSSupport.fetchPosition(container).rawValue == positionBefore)
        let survivors = Set(try Self.retainedIDs(container))
        #expect(survivors == Set([heavy1.id, heavy2.id]))
        #expect(try Self.fetchBytesRows(container).count == 2)
    }

    // MARK: - R3-only config takes the exact v1 route (V2-02 §4.2 note, §7)

    /// An R3-only config (R1 nil, R2 nil, R3 enabled with
    /// `maxRevisionsPerItem = 1`) leaves the capture path exactly v1: the
    /// over-threshold item (2 stored revisions > 1) is NOT pruned — capture
    /// does not grow any item's revisions, so R3 never fires on capture
    /// (§7) — and no item is retired. The expansion fact load never runs
    /// (§4.2's R3-only note), which is what keeps the item's lineage
    /// untouched through the public capture.
    @Test("R3-only config: capture is exactly v1 — no prune, no retirement")
    func r3OnlyConfigLeavesCaptureExactlyV1() async throws {
        let storeURL = WSSupport.tempStoreURL("r4-r3-only")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let base = try await Self.capture(
            "r4 r3-only item base", at: 700_500_000, source: "com.example.r4.r3",
            in: history
        )
        for version in [ContentVersion(rawValue: 1), ContentVersion(rawValue: 2)] {
            let reviseReceipt = try await history.perform(.revise(RevisionRequest(
                itemID: base.id,
                expected: version,
                intent: .replace(RevisionDraft(decisions: [
                    RevisionDecision(
                        typeIdentifier: "public.utf8-plain-text",
                        action: .replace(bytes: Data(String(
                            "r4 r3-only revision \(version.rawValue)"
                        ).utf8))
                    ),
                ]))
            )))
            guard case .committed = reviseReceipt else {
                Issue.record("R.4 setup: expected a committed revise, got \(reviseReceipt)")
                return
            }
        }
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            revisions: RevisionRetention(
                maxRevisionsPerItem: 1,
                maxRevisionBytesPerItem: nil
            )
        )

        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                "r4 r3-only primary pp",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_500_400),
                source: "com.example.r4.r3"
            )
        ))
        guard case .committed = receipt else {
            Issue.record("R.4: expected a committed capture, got \(receipt)")
            return
        }

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        // No retirement: the over-threshold item AND the new primary remain.
        let survivors = try Self.retainedIDs(container)
        #expect(survivors.count == 2)
        #expect(survivors.contains(base.id))
        // No prune: the item still carries its 2 stored revisions — capture
        // never prunes (§7); R3's sweep lane is R.6.
        let facts = try MutationFactLoaders.loadRevisionFacts(
            itemID: base.id,
            in: ModelContext(container)
        )
        #expect(facts.item.revisions.count == 2)
    }

    // MARK: - Disabled (all-nil) config: identical v1 behavior (V2-02 §4.1/§7)

    /// An explicitly all-disabled config is the v1 route verbatim: three
    /// 25-byte items that are old AND would overflow a tight budget both
    /// survive an insert — nothing is retired, the config row is untouched
    /// by the capture, and the insert succeeds exactly as v1 (DC-04: only
    /// the mandatory projection maintenance differs durably, R.3).
    @Test("all-disabled config: insert works, nothing extra retired")
    func disabledConfigBehavesExactlyAsV1() async throws {
        let storeURL = WSSupport.tempStoreURL("r4-disabled")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        _ = try await Self.capture(
            String(repeating: "a", count: 25), at: 700_600_000, source: "com.example.r4.off",
            in: history
        )
        _ = try await Self.capture(
            String(repeating: "b", count: 25), at: 700_600_050, source: "com.example.r4.off",
            in: history
        )
        _ = try await Self.capture(
            String(repeating: "c", count: 25), at: 700_600_100, source: "com.example.r4.off",
            in: history
        )
        // Explicit all-nil seed: flags false, dormant values zeroed.
        try WSSupport.seedRetentionConfig(storeURL: storeURL)

        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                String(repeating: "p", count: 25),
                observedAt: Date(timeIntervalSinceReferenceDate: 700_600_400),
                source: "com.example.r4.off"
            )
        ))
        guard case .committed = receipt else {
            Issue.record("R.4: expected a committed capture, got \(receipt)")
            return
        }

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        #expect(try Self.retainedIDs(container).count == 4)
        // The capture path never writes the config singleton (the writer is
        // the R.6 `.setRetentionPolicies` stamping).
        let configs = try ModelContext(container)
            .fetch(FetchDescriptor<RetentionExpansionConfigRow>())
        #expect(configs.count == 1)
        let config = try #require(configs.first)
        #expect(config.agePolicyEnabled == false)
        #expect(config.storagePolicyEnabled == false)
        #expect(config.revisionPolicyEnabled == false)
    }

    // MARK: - Capture-lane config re-validation (V2-02 §3.3, §8.3)

    /// The capture lane re-validates the freshly fetched singleton on EVERY
    /// capture: a row corrupted between `open` and a later capture (here:
    /// `configSchemaVersion` bumped to an unknown version behind the
    /// Authority's back) fails the capture closed as
    /// `.persistence(.corruptStoredValue)` — the open-time bootstrap's exact
    /// producer, re-run per capture by
    /// `RetentionConfigLoading.loadCaptureLanePolicies` — never
    /// `.invalidInput` (reserved for the caller-facing policy-set boundary,
    /// R.6) and never a silently-disabled read (§3.3/§8.3). The re-validation
    /// runs even on the would-be-v1 route (all lanes disabled here), and the
    /// failure is pre-stamp: the position does not move and no projection
    /// row lands for the rejected probe.
    @Test("config corrupted mid-run fails the next capture as corruptStoredValue")
    func corruptedConfigFailsNextCaptureClosed() async throws {
        let storeURL = WSSupport.tempStoreURL("r4-config-corruption")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        _ = try await Self.capture(
            "r4 corruption baseline", at: 700_900_000, source: "com.example.r4.corrupt",
            in: history
        )

        // Damage the singleton behind the Authority's back: an unknown
        // `configSchemaVersion` is forward-incompatible (the 05 §4 codec
        // discipline; the same mutation the bootstrap corruption matrix
        // drives). Same-context fetch-mutate-save — a `@Model` is bound to
        // the context that fetched it (the R.3 fixture stance).
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<RetentionExpansionConfigRow>())
        precondition(
            rows.count == 1,
            "config singleton must exist exactly once, got \(rows.count)"
        )
        rows[0].configSchemaVersion = 2
        try context.save()

        let positionBefore = try WSSupport.fetchPosition(container).rawValue
        #expect(positionBefore == 1)

        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            _ = try await history.perform(.capture(
                WSSupport.textCapture(
                    "r4 corruption probe",
                    observedAt: Date(timeIntervalSinceReferenceDate: 700_900_100),
                    source: "com.example.r4.corrupt"
                )
            ))
        }
        // Pre-stamp failure: nothing landed.
        #expect(try WSSupport.fetchPosition(container).rawValue == positionBefore)
        #expect(try Self.fetchBytesRows(container).count == 1)
    }

    // MARK: - Zero blob decodes on the planning path (RET-PLATFORM-2, RET-PERF-3)

    /// The behavioral zero-decode proof for the CAPTURE planning lane
    /// (`V2-02` §3.2/Record 3 `RET-PLATFORM-2`/`RET-PERF-3` — the mirror of
    /// the R.6 sweep fixture
    /// `r3SweepPrunesExceedingItemsOnlyWithoutDecodingNonExceeding`): with
    /// R2 active, a NON-primary item's `revisionStateBlob` is corrupted
    /// behind the Authority's back (independent container, the R.3 fixture
    /// stance) BEFORE the capture. The capture's expansion planning must
    /// read ONLY that item's `RetainedBytesRow` scalar columns
    /// (`RetentionConfigLoading.fetchProjectedScalars` — the
    /// `.externalStorage` blob columns are never touched); any
    /// `revisionStateBlob` decode on the planning path would fail the whole
    /// commit `.persistence(.corruptStoredValue)` (the 05 §4 codec
    /// discipline: never skip, never invent). The commit SUCCEEDS, the
    /// corrupt blob emerges byte-identical, and the corrupt item's stored
    /// scalars are provably planned over.
    ///
    /// Arithmetic (single-representation ASCII: canonicalBytes = UTF-8
    /// length; footprint = canonicalBytes + revisionBytes): B = 10 + 0
    /// (t=…000, oldest), A = 10 + [5] = 15 (t=…100, the corrupt victim,
    /// NON-primary), the inserted primary P = 20 + 0 (t=…400), under
    /// `maxTotalBytes = 35`. Crediting A's stored scalars: 10 + 15 + 20 =
    /// 45 > 35 → retire the oldest eligible B → 35 ≤ 35 → stop (never
    /// further). If A's scalars were NOT planned over (the discriminator),
    /// the projected total would be 10 + 20 = 30 ≤ 35 and NOTHING would
    /// retire — B's retirement is exactly the evidence that the corrupt
    /// item's SCALARS entered the projected inventory while its blob was
    /// never decoded.
    @Test("capture planning never decodes a non-primary item's revision blob (RET-PLATFORM-2)")
    func capturePlanningNeverDecodesNonPrimaryRevisionBlob() async throws {
        let storeURL = WSSupport.tempStoreURL("r4-zero-decode-capture")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let source = "com.example.r4.zerodecode"

        // Seed under the all-disabled default: B (oldest), then A, then A's
        // one 5-byte revision (positions 1, 2, 3).
        let b = try await Self.capture(
            String(repeating: "b", count: 10), at: 700_950_000,
            source: source, in: history
        )
        let a = try await Self.capture(
            String(repeating: "a", count: 10), at: 700_950_100,
            source: source, in: history
        )
        try await Self.revise(a.id, expected: 1, bytes: 5, in: history)

        // R2 lands now (capture fires R1+R2 only; the lane re-reads the
        // singleton inside every capture).
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            storage: StorageRetention(maxTotalBytes: 35)
        )

        // Corrupt A's revision blob through an INDEPENDENT container (the
        // R.3/R.6 fixture stance): a 1-byte blob fails every decode shape.
        // A is NOT the capture's primary — the incoming P is.
        let corruptBlob = Data([0x00])
        let damageContainer = try WSSupport.makeContainer(storeURL: storeURL)
        let damageContext = ModelContext(damageContainer)
        let damageRow = try #require(
            try damageContext.fetch(FetchDescriptor<HistoryItemRow>())
                .first { $0.id == a.id.rawValue }
        )
        damageRow.revisionStateBlob = corruptBlob
        try damageContext.save()

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let positionBefore = try WSSupport.fetchPosition(container).rawValue
        #expect(positionBefore == 3)

        // The public capture MUST succeed — a planning-path decode of A's
        // corrupt blob would fail the commit `.corruptStoredValue`.
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                String(repeating: "p", count: 20),
                observedAt: Date(timeIntervalSinceReferenceDate: 700_950_400),
                source: source
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .inserted(primary) = commit.outcome else {
            Issue.record("R.4: expected .committed with .inserted, got \(receipt)")
            return
        }

        // A's stored scalars were planned over: B (the oldest eligible)
        // retired exactly as the arithmetic pins; ONE position advance for
        // the merged insert+retirement commit (D6/D24(a)).
        #expect(commit.position.rawValue == positionBefore + 1)
        let survivors = Set(try Self.retainedIDs(container))
        #expect(survivors == Set([a.id, primary.id]))
        #expect(!survivors.contains(b.id))
        #expect(try Self.fetchBytesRows(container).count == 2)
        #expect(try WSSupport.fetchPosition(container).rawValue == positionBefore + 1)

        // The corrupt blob is byte-identical — zero decodes AND zero writes
        // for the non-primary item — and its projection row still carries
        // the stored scalars the plan consumed (10 / 1 / 5).
        let untouchedRow = try #require(
            try WSSupport.fetchRows(container)
                .first { $0.id == a.id.rawValue }
        )
        #expect(untouchedRow.revisionStateBlob == corruptBlob)
        let aRow = try #require(try Self.fetchBytesRow(for: a.id, in: container))
        #expect(aRow.canonicalBytes == 10)
        #expect(aRow.revisionCount == 1)
        #expect(aRow.revisionBytes == 5)
        // The primary's row was stamped at 20 / 0 / 0 (R.3 insert stamping).
        let primaryRow = try #require(
            try Self.fetchBytesRow(for: primary.id, in: container)
        )
        #expect(primaryRow.canonicalBytes == 20)
        #expect(primaryRow.revisionCount == 0)
        #expect(primaryRow.revisionBytes == 0)
    }

    // MARK: - Coalesce lane (V2-02 §3.2 coalesce lane, §6.3, D14)

    /// Coalesce uses the WINNER's stored bytes and leaves its projection row
    /// unchanged: a rich winner (23-byte plain + 16-byte `public.html` = 39
    /// canonical bytes) coalesced by a plain-only subset capture (23 bytes)
    /// succeeds under `maxTotalBytes = 40` — the projected inventory credits
    /// the winner's 39 STORED bytes, never the incoming 23 — and the
    /// winner's `RetainedBytesRow` scalars are identical before and after
    /// (coalesce stamps only `.updateOccurrence`; no new projection stamp,
    /// the R.3 law). With R1 also active and the winner captured 500 s
    /// before the coalesce, the coalesced primary survives: its post-primary
    /// recency is the folded `max()` (D14's projected-state guarantee).
    @Test("coalesce uses winner stored bytes; projection row unchanged; primary protected")
    func coalesceUsesWinnerStoredBytesAndLeavesRowUnchanged() async throws {
        let storeURL = WSSupport.tempStoreURL("r4-coalesce-stored-bytes")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let winner = try await Self.capture(
            "r4 coalesce winner base",
            at: 700_700_000,
            source: "com.example.r4.coalesce",
            in: history,
            // Rich capture: the plain representation plus a 16-byte html
            // extra → canonicalBytes = 23 + 16 = 39.
            extra: [("public.html", Array("0123456789abcdef".utf8))]
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            age: AgeRetention(maxAge: 300),
            storage: StorageRetention(maxTotalBytes: 40)
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let rowBefore = try Self.fetchBytesRow(for: winner.id, in: container)
        let before = try #require(rowBefore)
        #expect(before.canonicalBytes == 39)
        #expect(before.revisionCount == 0)
        #expect(before.revisionBytes == 0)

        // Plain-only subset (WS3's containment lane): the rich winner
        // contains it, so the capture coalesces onto the winner.
        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                "r4 coalesce winner base",
                observedAt: Date(timeIntervalSinceReferenceDate: 700_700_500),
                source: "com.example.r4.coalesce"
            )
        ))
        guard case let .committed(commit) = receipt,
              case let .coalesced(coalesced) = commit.outcome else {
            Issue.record("R.4: expected .committed with .coalesced, got \(receipt)")
            return
        }
        #expect(coalesced.id == winner.id)

        // The winner's row is unchanged (R.3 law: no restamp on coalesce),
        // the winner survives as the protected primary, and exactly one row
        // plus one item remain.
        let rowAfter = try Self.fetchBytesRow(for: winner.id, in: container)
        let after = try #require(rowAfter)
        #expect(after.canonicalBytes == before.canonicalBytes)
        #expect(after.revisionCount == before.revisionCount)
        #expect(after.revisionBytes == before.revisionBytes)
        #expect(try Self.retainedIDs(container) == [winner.id])
        #expect(try Self.fetchBytesRows(container).count == 1)
    }

    /// The stored-bytes discriminator: the same rich winner (39 stored
    /// bytes) under `maxTotalBytes = 30` — above the incoming 23 but below
    /// the stored 39 — makes the coalescing capture fail
    /// `.capacityExceeded(.storageBytes)`: the pre-plan feasibility check
    /// credits the WINNER's stored scalars (§3.2 coalesce lane:
    /// substituting the incoming capture blob "would undercount the
    /// primary's retained bytes and could leave the store over budget").
    /// The failure is atomic: the winner survives with its row unchanged
    /// and the singleton position does not move.
    @Test("coalesce feasibility credits winner stored bytes, not incoming bytes")
    func coalesceFeasibilityCreditsWinnerStoredBytes() async throws {
        let storeURL = WSSupport.tempStoreURL("r4-coalesce-feasibility")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)

        let winner = try await Self.capture(
            "r4 coalesce winner base",
            at: 700_710_000,
            source: "com.example.r4.coalesceFail",
            in: history,
            extra: [("public.html", Array("0123456789abcdef".utf8))]
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            storage: StorageRetention(maxTotalBytes: 30)
        )

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let positionBefore = try WSSupport.fetchPosition(container).rawValue
        #expect(positionBefore == 1)

        await #expect(throws: HistoryFailure.capacityExceeded(.storageBytes)) {
            _ = try await history.perform(.capture(
                WSSupport.textCapture(
                    "r4 coalesce winner base",
                    observedAt: Date(timeIntervalSinceReferenceDate: 700_710_500),
                    source: "com.example.r4.coalesceFail"
                )
            ))
        }

        // Atomic: the winner (and only the winner) survives, its projection
        // row still carries the 39 stored bytes, and the position did not
        // move — the occurrence fold never landed.
        #expect(try Self.retainedIDs(container) == [winner.id])
        let rowAfter = try Self.fetchBytesRow(for: winner.id, in: container)
        let row = try #require(rowAfter)
        #expect(row.canonicalBytes == 39)
        #expect(try WSSupport.fetchPosition(container).rawValue == positionBefore)
    }

    // MARK: - Post-count exclusion (V2-02 §4.2 projected inventory)

    /// A count-plan victim's bytes do NOT count toward the R2 total: with
    /// `maximumUnpinnedItems = 2`, X(40 B, t=…000) and Y(5 B, t=…100) fill
    /// the count; the insert of P(5 B, t=…400) makes the v1 count plan
    /// retire X (the oldest). The projected inventory EXCLUDES X, so the
    /// R2 total is Y(5) + P(5) = 10 ≤ 30 and nothing else retires — Y
    /// survives. (If X's 40 bytes were wrongly credited, the total 50 > 30
    /// would additionally retire Y, the only remaining eligible victim.)
    @Test("count-plan victim bytes are excluded from the projected R2 total")
    func countVictimBytesAreExcludedFromProjectedTotal() async throws {
        let storeURL = WSSupport.tempStoreURL("r4-post-count-exclusion")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL, maximumUnpinned: 2)

        let x = try await Self.capture(
            String(repeating: "x", count: 40), at: 700_800_000, source: "com.example.r4.excl",
            in: history
        )
        let y = try await Self.capture(
            String(repeating: "y", count: 5), at: 700_800_100, source: "com.example.r4.excl",
            in: history
        )
        try WSSupport.seedRetentionConfig(
            storeURL: storeURL,
            storage: StorageRetention(maxTotalBytes: 30)
        )

        let receipt = try await history.perform(.capture(
            WSSupport.textCapture(
                String(repeating: "p", count: 5),
                observedAt: Date(timeIntervalSinceReferenceDate: 700_800_400),
                source: "com.example.r4.excl"
            )
        ))
        guard case .committed = receipt else {
            Issue.record("R.4: expected a committed capture, got \(receipt)")
            return
        }

        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let survivors = Set(try Self.retainedIDs(container))
        // X is the count victim; Y and the primary survive — nothing else
        // was retired for bytes.
        #expect(!survivors.contains(x.id))
        #expect(survivors.contains(y.id))
        #expect(survivors.count == 2)
        #expect(try Self.fetchBytesRows(container).count == 2)
    }
}
