/// Durable retention policy and retained-content byte accounting.
/// Models remain internal to HistoryStorage (01 §2; V2-02 §3.3).
import Foundation
import SwiftData

/// Persisted retention policies singleton (`V2-02` §3.3). One row, keyed
/// `key == "retention-expansion"`, following the `LastChangePositionRow`
/// singleton pattern (`05` §3.2). Created at `open` with every optional
/// policy disabled (`V2-roadmap` §5 total open order step 5; M1.3).
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
/// A missing row for an existing item is
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
