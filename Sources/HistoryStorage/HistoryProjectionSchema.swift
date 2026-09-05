/// V5 adds byte-preserving projection storage without changing the frozen V1–V4
/// model shapes. The legacy String column remains for additive migration;
/// startup rebuilds both fields from content lineage before ordinary reads.
/// Owning spec: docs/05-authority-kernel.md §3, §13, §15.
import Foundation
import SwiftData

internal enum HistorySchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            HistorySchemaV5.HistoryItemRow.self,
            LastChangePositionRow.self,
            RetentionExpansionConfigRow.self,
            RetainedBytesRow.self,
            ConnectionRow.self,
            GrantRow.self,
            OperationRecordRow.self,
            GatewayConfigRow.self,
            HistoryChangeRecordRow.self,
            JournalConfigRow.self,
        ]
    }

    /// The current retained item model. Every pre-existing persisted field
    /// retains its name, type and attributes; both UTF-8 fields are additive.
    @Model
    internal final class HistoryItemRow {
        @Attribute(.unique)
        var id: UUID

        var contentVersionRaw: UInt64

        @Attribute(.externalStorage)
        var canonicalBlob: Data

        @Attribute(.externalStorage)
        var revisionStateBlob: Data

        var canonicalSignatureBlob: Data

        var projectionSchemaVersion: UInt16
        /// Legacy V1–V4 migration column, never the current title authority.
        var title: String
        /// UTF-8 content bytes preserve a leading U+FEFF across materialization.
        /// The empty migration default is replaced by the startup projection
        /// rebuild for every older recipe; new rows initialize the real bytes.
        var titleUTF8: Data = Data()
        /// Legacy V1–V4 migration column, not the current search authority.
        var searchBody: String
        /// Literal content bytes, decoded strictly only by body-reading paths.
        var searchBodyUTF8: Data = Data()
        var effectiveTypeIdentifiersBlob: Data

        var firstCopiedAt: Date
        var lastCopiedAt: Date
        var copyCount: UInt64
        var firstSource: String?
        var lastSource: String?

        var pinOrdinal: Int?

        init(
            id: UUID,
            contentVersionRaw: UInt64,
            canonicalBlob: Data,
            revisionStateBlob: Data,
            canonicalSignatureBlob: Data,
            projectionSchemaVersion: UInt16,
            title: String,
            searchBody: String,
            effectiveTypeIdentifiersBlob: Data,
            firstCopiedAt: Date,
            lastCopiedAt: Date,
            copyCount: UInt64,
            firstSource: String?,
            lastSource: String?,
            pinOrdinal: Int?
        ) {
            self.id = id
            self.contentVersionRaw = contentVersionRaw
            self.canonicalBlob = canonicalBlob
            self.revisionStateBlob = revisionStateBlob
            self.canonicalSignatureBlob = canonicalSignatureBlob
            self.projectionSchemaVersion = projectionSchemaVersion
            self.title = ""
            self.titleUTF8 = Data(title.utf8)
            self.searchBody = ""
            self.searchBodyUTF8 = Data(searchBody.utf8)
            self.effectiveTypeIdentifiersBlob = effectiveTypeIdentifiersBlob
            self.firstCopiedAt = firstCopiedAt
            self.lastCopiedAt = lastCopiedAt
            self.copyCount = copyCount
            self.firstSource = firstSource
            self.lastSource = lastSource
            self.pinOrdinal = pinOrdinal
        }
    }
}

/// Current Authority operations use V5; historical migrations and fixtures
/// explicitly name HistorySchemaV1.HistoryItemRow instead of this alias.
internal typealias HistoryItemRow = HistorySchemaV5.HistoryItemRow
