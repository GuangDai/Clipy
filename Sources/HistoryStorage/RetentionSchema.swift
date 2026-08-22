/// V2-02 retention-expansion schema additions (`HistorySchemaV2`,
/// `V2-roadmap` §5 M1.2). Under DC-03 incremental shipping the first shipped
/// V2 schema carries **only** the retention rows: the frozen v1 models plus
/// `RetentionExpansionConfigRow` and `RetainedBytesRow` (`V2-02` §3.3).
/// Access rule unchanged (`01` §2): all model types stay internal to
/// HistoryStorage and never occur in a public or package signature.
import Foundation
import SwiftData

/// The first shipped V2 schema (`HistorySchemaV2`, `V2-02` §3.3): the frozen
/// v1 model set (`05` §3) plus the two additive retention rows below.
/// Immutable once shipped (`V2-roadmap` §5 M1.2): later admitted grafts
/// receive `HistorySchemaV3+`, never an edit of this type. The
/// `V1 → V2` hop is one `MigrationStage.custom` stage (DC-02; `V2-02` §3.3
/// "Stage topology"): the schema ADD is expressed by the versioned schemas
/// themselves and the `RetainedBytesRow` backfill runs in the stage's
/// `didMigrate`.
internal enum HistorySchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            HistoryItemRow.self,
            LastChangePositionRow.self,
            RetentionExpansionConfigRow.self,
            RetainedBytesRow.self
        ]
    }
}

/// Persisted V2 retention policies singleton (`V2-02` §3.3). One row, keyed
/// `key == "retention-expansion"`, mirroring the v1 `LastChangePositionRow`
/// singleton pattern (`05` §3.2). Created at `open` with every policy
/// disabled — never by the migration — so a migrated v1 store starts
/// v1-faithful (`V2-roadmap` §5 total open order step 5; M1.3).
///
/// `configSchemaVersion` follows the codec discipline of a blob
/// `formatVersion` (`05` §4): `open` validates `configSchemaVersion == 1`;
/// an unknown version, a non-finite `ageMaxSeconds` (DC-21), or a
/// contradictory field combination (e.g. `revisionPolicyEnabled` with both
/// thresholds nil) fails closed as `.persistence(.corruptStoredValue)` /
/// `.persistence(.invariantViolation)` rather than being silently treated as
/// disabled. An absent row is the only create-with-defaults path. `.unique`
/// conflict semantics are undocumented; the single-writer Authority (no
/// concurrent inserts) is the reliance (`V2-02` §3.3).
@Model
internal final class RetentionExpansionConfigRow {
    @Attribute(.unique)
    var key: String                 // always "retention-expansion"

    // R1
    var agePolicyEnabled: Bool
    var ageMaxSeconds: Double       // TimeInterval

    // R2
    var storagePolicyEnabled: Bool
    var storageMaxBytes: Int        // Int64 on macOS; holds the 5,000 x 384
                                    // MiB worst case (V2-02 §3.3)

    // R3
    var revisionPolicyEnabled: Bool
    var revisionMaxCount: Int?      // nil = no count limit
    var revisionMaxBytes: Int?      // nil = no byte limit

    var configSchemaVersion: UInt16 // 1 for V2-02

    init(
        key: String,
        agePolicyEnabled: Bool,
        ageMaxSeconds: Double,
        storagePolicyEnabled: Bool,
        storageMaxBytes: Int,
        revisionPolicyEnabled: Bool,
        revisionMaxCount: Int?,
        revisionMaxBytes: Int?,
        configSchemaVersion: UInt16
    ) {
        self.key = key
        self.agePolicyEnabled = agePolicyEnabled
        self.ageMaxSeconds = ageMaxSeconds
        self.storagePolicyEnabled = storagePolicyEnabled
        self.storageMaxBytes = storageMaxBytes
        self.revisionPolicyEnabled = revisionPolicyEnabled
        self.revisionMaxCount = revisionMaxCount
        self.revisionMaxBytes = revisionMaxBytes
        self.configSchemaVersion = configSchemaVersion
    }
}

/// Per-item byte projection row (`V2-02` §3.3b) — a v1-style content-byte
/// projection of the same kind as `title`/`searchBody` (`05` §15), stamped in
/// the same `ModelContext.transaction` as the blob write it summarizes;
/// never a cache and never a new blob codec (`V2-02` §3.4). 1:1 with
/// `HistoryItemRow` (same lifecycle): deleted by an explicit step in the
/// V2-extended `.delete` stamping, not by a `@Relationship` on the frozen v1
/// model. A v1 insert carries an empty revision list (`02` §2), so the
/// insert-time stamp is `revisionCount == 0` / `revisionBytes == 0` (DC-04).
///
/// `bytesSchemaVersion` is the projection-coherence fence: a row with an
/// unknown version, or scalars inconsistent with the item's actual blob,
/// fails closed (`05` §4/§16) — never silently used as a stale byte fact.
/// A missing row for an existing item post-backfill is
/// `.persistence(.invariantViolation)` (`V2-02` Record 5).
@Model
internal final class RetainedBytesRow {
    @Attribute(.unique)
    var itemID: UUID                // HistoryItemID.rawValue; 1:1 with
                                    // HistoryItemRow (v1 business IDs are
                                    // UUID-backed, `03a` §2 — DC-04)

    var canonicalBytes: Int         // sum of StoredSignatureEntryV1.byteCount (05 §4)
    var revisionCount: Int          // count of stored revisions
    var revisionBytes: Int          // sum of stored-revision representation bytes
    var bytesSchemaVersion: UInt16  // 1 for V2-02

    init(
        itemID: UUID,
        canonicalBytes: Int,
        revisionCount: Int,
        revisionBytes: Int,
        bytesSchemaVersion: UInt16
    ) {
        self.itemID = itemID
        self.canonicalBytes = canonicalBytes
        self.revisionCount = revisionCount
        self.revisionBytes = revisionBytes
        self.bytesSchemaVersion = bytesSchemaVersion
    }
}
