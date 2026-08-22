/// M1.4/M1 — the single-hop V1 → V2 migration plan.
/// Owning spec: `V2-02` §3.3 "Stage topology" (DC-02, closed 2026-08-15) and
/// Record 5 ("Schema layer"); `V2-roadmap` §5 M1 total open order step 2;
/// platform facts: `V2-facts.md` cycle-2 (SwiftData schema migration:
/// `MigrationStage.custom(fromVersion:toVersion:willMigrate:didMigrate:)`,
/// `macOS 14.0+`, present on macOS 26; `ModelContainer.init(for:
/// migrationPlan:configurations:)`; the custom-stage closures are
/// `(@Sendable (ModelContext) throws -> Void)?` — verified against the
/// Apple `MigrationStage.custom` reference page).
///
/// ONE custom stage owns the whole hop (DC-02): the schema ADD of the two
/// retention rows is expressed by the versioned schemas themselves — purely
/// additive, no v1 row or column is rewritten — and the `RetainedBytesRow`
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
/// open order step 5.
import SwiftData

// MARK: - Migration plan (V2-02 §3.3 Stage topology, DC-02)

internal enum HistoryMigrationPlan: SchemaMigrationPlan {

    /// The ordered schema history in ship order (DC-03 incremental
    /// shipping): the frozen v1 anchor (`V2-roadmap` §5 M1.1), then the
    /// first shipped V2 schema carrying only the retention rows
    /// (`V2-roadmap` §5 M1.2).
    internal static var schemas: [any VersionedSchema.Type] {
        [HistorySchemaV1.self, HistorySchemaV2.self]
    }

    /// EXACTLY ONE stage: the single custom `V1 → V2` hop whose `didMigrate`
    /// performs the projection backfill (DC-02; `V2-02` Record 5). A fresh
    /// store runs no stage — the V2 schema is created directly; a v1 store
    /// migrates during `ModelContainer` construction. The backfill is
    /// idempotent by construction (`RET-PLATFORM-1b(e)`), so an engine-level
    /// re-run reproduces exactly the same rows.
    internal static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: HistorySchemaV1.self,
                toVersion: HistorySchemaV2.self,
                willMigrate: nil,
                didMigrate: { context in
                    try RetainedBytesBackfill.backfill(in: context)
                }
            )
        ]
    }
}
