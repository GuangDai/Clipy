import Foundation
import HistoryCore

/// Current SQLite layout (V2-09 §§3–6). The Authority creates an empty store
/// inside its startup transaction. Reopen recognizes these tables without
/// rebuilding data or indexes; a different/partial schema is not repaired.
internal enum SQLiteHistorySchema {
    internal static func create(in database: SQLiteDatabase) throws {
        let existing = try database.prepare("""
            SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name IN (
                'history_state', 'history_items', 'contents', 'representations',
                'retention_policies', 'connections', 'grants', 'operation_records',
                'gateway_config', 'history_change_records', 'journal_config'
            )
            """)
        guard try existing.step() else { throw HistoryFailure.persistence(.openStore) }
        let currentTableCount = try existing.integer(at: 0)
        existing.finalize()
        if currentTableCount == 11 { return }

        let occupied = try database.prepare("""
            SELECT 1 FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' LIMIT 1
            """)
        let hasExistingSchema = try occupied.step()
        occupied.finalize()
        guard !hasExistingSchema else { throw HistoryFailure.persistence(.openStore) }

        // No nested transaction: startup's one write transaction includes the
        // DDL and the business singleton/bootstrap rows supplied by its owners.
        for sql in statements { try database.execute(sql) }
    }

    private static let statements = [
        """
        CREATE TABLE history_state (
            key TEXT PRIMARY KEY NOT NULL CHECK (key = 'retained-history'),
            changePosition BLOB NOT NULL CHECK (length(changePosition) = 8),
            maximumUnpinnedItems INTEGER NOT NULL CHECK (maximumUnpinnedItems > 0),
            retainedItemCount INTEGER NOT NULL DEFAULT 0 CHECK (retainedItemCount >= 0),
            pinnedItemCount INTEGER NOT NULL DEFAULT 0 CHECK (pinnedItemCount >= 0),
            canonicalBytes INTEGER NOT NULL DEFAULT 0 CHECK (canonicalBytes >= 0),
            revisionBytes INTEGER NOT NULL DEFAULT 0 CHECK (revisionBytes >= 0)
        )
        """,
        """
        CREATE TABLE history_items (
            id TEXT PRIMARY KEY NOT NULL,
            contentVersion BLOB NOT NULL CHECK (length(contentVersion) = 8),
            currentContentID TEXT NOT NULL REFERENCES contents(id) DEFERRABLE INITIALLY DEFERRED,
            titleUTF8 BLOB NOT NULL,
            searchBodyUTF8 BLOB NOT NULL,
            effectiveTypeIdentifiersBlob BLOB NOT NULL,
            effectiveMatchesCanonical INTEGER NOT NULL CHECK (effectiveMatchesCanonical IN (0, 1)),
            firstCopiedAt REAL NOT NULL,
            lastCopiedAt REAL NOT NULL,
            copyCount BLOB NOT NULL CHECK (length(copyCount) = 8),
            firstSource TEXT,
            lastSource TEXT,
            pinOrdinal INTEGER CHECK (pinOrdinal >= 0),
            canonicalBytes INTEGER NOT NULL CHECK (canonicalBytes >= 0),
            revisionCount INTEGER NOT NULL CHECK (revisionCount >= 0),
            revisionBytes INTEGER NOT NULL CHECK (revisionBytes >= 0)
        )
        """,
        """
        CREATE TABLE contents (
            id TEXT PRIMARY KEY NOT NULL,
            itemID TEXT NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
            revisionOrdinal INTEGER NOT NULL CHECK (revisionOrdinal >= 0),
            createdAt REAL NOT NULL,
            titleUTF8 BLOB NOT NULL,
            contentByteCount INTEGER NOT NULL CHECK (contentByteCount > 0),
            representationCount INTEGER NOT NULL CHECK (representationCount > 0),
            UNIQUE (itemID, revisionOrdinal)
        )
        """,
        """
        CREATE TABLE representations (
            contentID TEXT NOT NULL REFERENCES contents(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
            exactType TEXT NOT NULL,
            typeKey TEXT NOT NULL,
            byteCount INTEGER NOT NULL CHECK (byteCount > 0),
            fingerprint BLOB CHECK (fingerprint IS NULL OR length(fingerprint) = 8),
            inlineBytes BLOB,
            blobID TEXT,
            PRIMARY KEY (contentID, ordinal),
            UNIQUE (contentID, typeKey),
            CHECK ((inlineBytes IS NULL) <> (blobID IS NULL)),
            CHECK (inlineBytes IS NULL OR length(inlineBytes) = byteCount)
        )
        """,
        """
        CREATE TABLE retention_policies (
            key TEXT PRIMARY KEY NOT NULL CHECK (key = 'retention-expansion'),
            ageMaxSeconds REAL CHECK (ageMaxSeconds > 0),
            storageMaxBytes INTEGER CHECK (storageMaxBytes > 0),
            revisionMaxCount INTEGER CHECK (revisionMaxCount > 0),
            revisionMaxBytes INTEGER CHECK (revisionMaxBytes > 0)
        )
        """,
        """
        CREATE TABLE connections (
            id TEXT PRIMARY KEY NOT NULL,
            displayNameRaw TEXT NOT NULL,
            enrollKindRaw INTEGER NOT NULL,
            statusRaw INTEGER NOT NULL,
            enrolledAt REAL NOT NULL,
            revokedAt REAL,
            configSchemaVersion INTEGER NOT NULL DEFAULT 1
        )
        """,
        """
        CREATE TABLE grants (
            grantKey TEXT PRIMARY KEY NOT NULL,
            connectionIDRaw TEXT NOT NULL REFERENCES connections(id),
            capabilityRaw INTEGER NOT NULL,
            grantedAt REAL NOT NULL,
            revokedAt REAL,
            configSchemaVersion INTEGER NOT NULL DEFAULT 1,
            UNIQUE (connectionIDRaw, capabilityRaw)
        )
        """,
        """
        CREATE TABLE operation_records (
            auditSequence BLOB PRIMARY KEY NOT NULL CHECK (length(auditSequence) = 8),
            connectionIDRaw TEXT,
            capabilityRaw INTEGER,
            operationKindRaw INTEGER NOT NULL,
            outcomeRaw INTEGER NOT NULL,
            failureKindRaw INTEGER,
            denialReasonRaw INTEGER,
            payloadBlob BLOB NOT NULL,
            requestedAt REAL NOT NULL,
            committedAt REAL NOT NULL,
            changePositionRaw BLOB CHECK (changePositionRaw IS NULL OR length(changePositionRaw) = 8),
            auditSchemaVersion INTEGER NOT NULL DEFAULT 1
        )
        """,
        """
        CREATE TABLE gateway_config (
            key TEXT PRIMARY KEY NOT NULL CHECK (key = 'external-gateway'),
            appIntentsConnectionID TEXT NOT NULL,
            nextAuditSequence BLOB NOT NULL CHECK (length(nextAuditSequence) = 8),
            auditBytes BLOB NOT NULL CHECK (length(auditBytes) = 8),
            compactionFloor BLOB NOT NULL CHECK (length(compactionFloor) = 8),
            configSchemaVersion INTEGER NOT NULL DEFAULT 1
        )
        """,
        """
        CREATE TABLE history_change_records (
            sequence BLOB PRIMARY KEY NOT NULL CHECK (length(sequence) = 8),
            changePositionRaw BLOB NOT NULL CHECK (length(changePositionRaw) = 8),
            changeKindRaw INTEGER NOT NULL,
            affectedItemsBlob BLOB NOT NULL,
            createdAt REAL NOT NULL
        )
        """,
        """
        CREATE TABLE journal_config (
            key TEXT PRIMARY KEY NOT NULL CHECK (key = 'change-journal'),
            compactionFloorRaw BLOB NOT NULL CHECK (length(compactionFloorRaw) = 8),
            journalBytes BLOB NOT NULL CHECK (length(journalBytes) = 8),
            configSchemaVersion INTEGER NOT NULL DEFAULT 1
        )
        """,
        """
        CREATE INDEX history_items_pinned_order ON history_items(pinOrdinal)
            WHERE pinOrdinal IS NOT NULL
        """,
        """
        CREATE INDEX history_items_recent_order ON history_items(lastCopiedAt DESC, id ASC)
            WHERE pinOrdinal IS NULL
        """,
        """
        CREATE INDEX history_items_retention_order ON history_items(lastCopiedAt ASC, id ASC)
            WHERE pinOrdinal IS NULL
        """,
        """
        CREATE INDEX representations_dedup ON representations(typeKey, byteCount, fingerprint, contentID)
            WHERE fingerprint IS NOT NULL
        """,
        """
        CREATE INDEX representations_blob ON representations(blobID) WHERE blobID IS NOT NULL
        """,
        """
        CREATE INDEX operation_records_connection ON operation_records(connectionIDRaw, auditSequence)
        """,
    ]
}
