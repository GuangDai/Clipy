# V2 Schema-Version Ledger

> Immutable shipped-schema registry mandated by `V2-roadmap` §5 M1.2 ("Record
> a schema-version ledger"). Every shipped `VersionedSchema` is frozen at
> ship time; a later admitted graft receives the **next** version, never an
> edit of a shipped row set (DC-03 incremental shipping; `V2-02` §3.3
> "Incremental shipping"). Version numbers follow the actual shipping order.
> Machine-readable counterpart: `HistorySchemaV1` / `HistorySchemaV2` /
> `HistorySchemaV3` in
> `Sources/HistoryStorage/`.

| Version | Type | Shipped in | Model set (cumulative additions) | Owning grafts | Hop into this version |
|---|---|---|---|---|---|
| 1.0.0 | `HistorySchemaV1` | v1 (pre-V2 anchor retrofitted by M1.1, behavior-preserving) | `HistoryItemRow`, `LastChangePositionRow` | v1 (`05` §3) | — (greenfield) |
| 2.0.0 | `HistorySchemaV2` | first V2 release (M1 + V2-02, admitted 2026-08-15) | + `RetentionExpansionConfigRow`, `RetainedBytesRow` | V2-02 (R1/R2/R3) | one `MigrationStage.custom` V1→V2 (DC-02): schema ADD via the versioned schemas; `RetainedBytesRow` projection backfill in `didMigrate`, idempotent by construction, completes before `open` returns |
| 3.0.0 | `HistorySchemaV3` | V2-05 X.3 (admitted 2026-08-22) | + `ConnectionRow`, `GrantRow`, `OperationRecordRow`, `GatewayConfigRow` | V2-05 Gateway schema/bootstrap | one purely additive `MigrationStage.lightweight` V2→V3 (DC-03); post-migration Authority bootstrap creates the deny-by-default App Intents connection/config pair separately from the migration stage |

Rules carried from the owning docs:

- A hop needing code beyond schema description is **one** custom stage; a
  purely-additive hop is one lightweight stage; two stages on one version
  pair is not a documented SwiftData pattern and is never used (DC-02,
  `V2-02` §3.3 "Stage topology").
- Blob codecs are versioned independently of schema rows (`05` §4); V2-02
  adds no codec (`V2-02` §3.4).
- Adding a row to this table requires: the graft's admission record, its
  Record 5 migration impact, the DC-ledger state for that graft, and a new
  immutable `VersionedSchema` type — recorded here at ship time with the
  release's CI run.
