/// M1.4/M1 + X.3 + J.2 — the ordered V1 → V2 → V3 → V4 migration plan.
/// Owning spec: `V2-02` §3.3 "Stage topology" (DC-02, closed 2026-08-15) and
/// Record 5 ("Schema layer"); `V2-roadmap` §5 M1 total open order step 2;
/// the X.3 additive Gateway schema slice (`V2-roadmap` §10 X.3; `V2-05`
/// §4 / Record 5), corrected by DC-03 incremental shipping;
/// platform facts: `V2-facts.md` cycle-2 (SwiftData schema migration:
/// `MigrationStage.custom(fromVersion:toVersion:willMigrate:didMigrate:)`,
/// `macOS 14.0+`, present on macOS 26; `ModelContainer.init(for:
/// migrationPlan:configurations:)`; the custom-stage closures are
/// `(@Sendable (ModelContext) throws -> Void)?` — verified against the
/// Apple `MigrationStage.custom` reference page).
///
/// The first custom stage owns the whole V1 → V2 hop (DC-02): the schema ADD
/// of the two retention rows is expressed by the versioned schemas themselves
/// — purely additive, no v1 row or column is rewritten — and the `RetainedBytesRow`
/// projection backfill runs in the stage's `didMigrate` closure, after the
/// hop's schema change with the new models writable, completing inside
/// `SwiftDataHistory.open` before it returns (`RET-PLATFORM-1b(d)`; whether
/// the backfill completes before `ModelContainer.init` itself returns is
/// runtime-asserted, not assumed — `V2-facts.md` cycle 7 §7.1 OPEN 5). A
/// lightweight+custom stage pair over one version pair is NOT a documented
/// SwiftData pattern and is not used. The custom-stage closures run on a
/// context the SwiftData migration machinery owns — the sole sanctioned
/// pre-Authority writer, an explicit recorded exception to the
/// Authority-only writable-context rule (`05` §2) owned by M1
/// (`V2-02` Record 5).
///
/// `RetentionExpansionConfigRow` is deliberately NOT created here: data
/// bootstrap is `open` (`V2-02` §3.3: a migrated store starts v1-faithful),
/// via `HistoryAuthority.ensureRetentionExpansionConfig(in:)` in the total
/// open order step 5. The lightweight V2 → V3 stage likewise creates no
/// Gateway data; the following Authority step atomically bootstraps the X.3
/// config/App Intents connection pair before facade publication. The HCR-only
/// V3 → V4 stage is also additive and performs no journal backfill or
/// singleton bootstrap: a migrated store first has both new tables empty.
import SwiftData

// MARK: - Migration plan (V2-02 §3.3 / X.3, DC-02 / DC-03)

internal enum HistoryMigrationPlan: SchemaMigrationPlan {

    /// The ordered schema history in ship order (DC-03 incremental
    /// shipping): the frozen v1 anchor (`V2-roadmap` §5 M1.1), then the
    /// first shipped V2 schema carrying only the retention rows
    /// (`V2-roadmap` §5 M1.2), then the additive Gateway/Audit schema
    /// (`V2-roadmap` §10 X.3), then the internal HCR-only V4 graft
    /// (`V2-roadmap` J.2/J.3; DC-25). Shipped schemas are never edited.
    internal static var schemas: [any VersionedSchema.Type] {
        [
            HistorySchemaV1.self,
            HistorySchemaV2.self,
            HistorySchemaV3.self,
            HistorySchemaV4.self,
        ]
    }

    /// Three ship-ordered stages: the custom `V1 → V2` hop whose `didMigrate`
    /// performs the projection backfill (DC-02; `V2-02` Record 5), followed
    /// by the purely additive lightweight `V2 → V3` Gateway-table hop
    /// (DC-03; X.3), then the additive lightweight `V3 → V4` HCR-table
    /// hop. A fresh store runs no stage and is created directly at V4; older
    /// stores migrate during `ModelContainer` construction. The retention
    /// backfill is idempotent by construction (`RET-PLATFORM-1b(e)`), so an
    /// engine-level re-run reproduces exactly the same rows. V3 → V4 inserts
    /// neither historical HCRs nor the later bootstrap singleton.
    internal static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: HistorySchemaV1.self,
                toVersion: HistorySchemaV2.self,
                willMigrate: nil,
                didMigrate: { context in
                    try RetainedBytesBackfill.backfill(in: context)
                }
            ),
            .lightweight(
                fromVersion: HistorySchemaV2.self,
                toVersion: HistorySchemaV3.self
            ),
            .lightweight(
                fromVersion: HistorySchemaV3.self,
                toVersion: HistorySchemaV4.self
            )
        ]
    }
}
