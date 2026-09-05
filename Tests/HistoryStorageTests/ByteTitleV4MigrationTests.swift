/// A genuine V4 file with recipe-5 String title damage migrates to byte-backed
/// titles. Frozen models seed the old schema; only the current public facade
/// opens/migrates and revises it. Raw History and journal facts stay intact.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

@MainActor
struct ByteTitleV4MigrationTests {
    private let canonicalAddress = "file:///%EF%BB%BFbefore.txt"
    private let activeAddress = "file:///%EF%BB%BFafter.txt"
    private let typeIdentifier = "public.file-url"

    private struct JournalValue: Equatable {
        let sequence: UInt64
        let position: UInt64
        let kind: Int16
        let bytes: Data
        let date: Date

        init(_ row: HistoryChangeRecordRow) {
            sequence = row.sequence
            position = row.changePositionRaw
            kind = row.changeKindRaw
            bytes = row.affectedItemsBlob
            date = row.createdAt
        }
    }

    private struct Seeded {
        let item: HistoryItemReference
        let canonicalBlob: Data
        let revisionBlob: Data
        let signatureBlob: Data
        let typeBlob: Data
        let revisionID: RevisionID
        let revisionDate: Date
        let occurrence: CopyOccurrenceSummary
        let journal: [JournalValue]
        let connectionID: UUID
    }

    @Test func recipe5DamagedTitleIsRebuiltWithoutChangingHistoryAndStaysFixedOnReopen() async throws {
        let storeURL = WSSupport.tempStoreURL("byte-title-v4-migration")
        defer { WSSupport.removeStore(storeURL) }
        let seeded = try await seedV4(at: storeURL)

        // This helper releases the migrated facade before the second open.
        let firstDetails = try await verifyFirstPublicOpen(at: storeURL, seeded: seeded)
        let reopened = try await WSSupport.openHistory(storeURL: storeURL)
        #expect(try await reopened.details(for: seeded.item.id) == firstDetails)
        try await expectTitle("\u{FEFF}after.txt", item: seeded.item, in: reopened)
        try expectPreservedRows(at: storeURL, seeded: seeded)

        let newestAddress = "file:///%EF%BB%BFnewest.txt"
        let receipt = try await reopened.perform(.revise(RevisionRequest(
            itemID: seeded.item.id,
            expected: seeded.item.contentVersion,
            intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                typeIdentifier: typeIdentifier, action: .replace(bytes: Data(newestAddress.utf8))
            )]))
        )))
        guard case let .committed(commit) = receipt,
              case let .revised(revised) = commit.outcome else {
            Issue.record("expected one real post-migration revision")
            return
        }
        #expect(commit.position.rawValue == 5)
        #expect(revised.id == seeded.item.id)
        #expect(revised.contentVersion.rawValue == 3)
        try await expectTitle("\u{FEFF}newest.txt", item: revised, in: reopened)
        let details = try await reopened.details(for: revised.id)
        #expect(details.canonical.map(\.bytes) == [Data(canonicalAddress.utf8)])
        #expect(details.effective.map(\.bytes) == [Data(newestAddress.utf8)])
        #expect(details.revisions.first?.id == seeded.revisionID)
        #expect(details.revisions.first?.createdAt == seeded.revisionDate)
        #expect(details.revisions.map { Data($0.title.utf8) }
            == [Data("\u{FEFF}after.txt".utf8), Data("\u{FEFF}newest.txt".utf8)])
        #expect(details.occurrence == seeded.occurrence)
        #expect(details.pinnedPosition == 0)
        let paste = try await reopened.pastePayload(for: revised.id)
        #expect(paste.item == revised)
        #expect(paste.representations.map(\.bytes) == [Data(newestAddress.utf8)])
        try expectNewRevisionStored(at: storeURL, seeded: seeded, newestAddress: newestAddress)
    }

    private func seedV4(at storeURL: URL) async throws -> Seeded {
        // Recent dates keep the independent journal age-compaction owner out
        // of this migration proof. No future timestamps or disabled hooks.
        let first = Date().addingTimeInterval(-10)
        let last = first.addingTimeInterval(1)
        let revisionDate = first.addingTimeInterval(3)
        let prepared = try await IngestPreparationActor().prepare(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: typeIdentifier, bytes: Data(canonicalAddress.utf8)
            )],
            origin: CopyOriginObservation(sourceApplication: "com.example.first", lineageHint: nil),
            observedAt: first
        ))
        let revisionID = RevisionID(rawValue: UUID())
        let revision = ContentRevision(
            id: revisionID, createdAt: revisionDate,
            content: EffectiveContent(representations: [ContentRepresentation(
                typeIdentifier: typeIdentifier, bytes: Data(activeAddress.utf8)
            )])
        )
        let canonicalBlob = try CanonicalBlobCodec.encode(prepared.domain.canonical)
        let revisionBlob = try RevisionStateBlobCodec.encode(revisions: [revision], activeRevisionID: revisionID)
        let signatureBlob = try SignatureBlobCodec.encode(prepared.signatureEntries)
        let typeBlob = try EffectiveTypeIdentifiersBlobCodec.encode([typeIdentifier])
        let schema = Schema(versionedSchema: HistorySchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = prepared.domain.candidateID
        // Explicit frozen type: the current HistoryItemRow alias must never
        // manufacture an allegedly old V4 store for this proof.
        context.insert(HistorySchemaV1.HistoryItemRow(
            id: id.rawValue, contentVersionRaw: 2,
            canonicalBlob: canonicalBlob, revisionStateBlob: revisionBlob,
            canonicalSignatureBlob: signatureBlob,
            projectionSchemaVersion: 5,
            title: "after.txt", // the observed old String-column damage
            searchBody: activeAddress + "\n/\u{FEFF}after.txt",
            effectiveTypeIdentifiersBlob: typeBlob,
            firstCopiedAt: first, lastCopiedAt: last, copyCount: 2,
            firstSource: "com.example.first", lastSource: "com.example.last", pinOrdinal: 0
        ))
        context.insert(LastChangePositionRow(key: "retained-history", rawValue: 4, maximumUnpinnedItems: 177))
        context.insert(RetainedBytesRow(
            itemID: id.rawValue, canonicalBytes: canonicalAddress.utf8.count,
            revisionCount: 1, revisionBytes: activeAddress.utf8.count, bytesSchemaVersion: 1
        ))
        context.insert(RetentionExpansionConfigRow(
            key: "retention-expansion", agePolicyEnabled: false, ageMaxSeconds: 0,
            storagePolicyEnabled: true, storageMaxBytes: 1_000_000,
            revisionPolicyEnabled: true, revisionMaxCount: 10, revisionMaxBytes: 8_192,
            configSchemaVersion: 1
        ))
        // Existing journal facts require an already valid Gateway bootstrap.
        let connectionID = UUID()
        context.insert(ConnectionRow(
            id: connectionID, displayNameRaw: "Siri / Shortcuts / Spotlight",
            enrollKindRaw: ConnectionEnrollKind.appIntents.rawValue,
            statusRaw: ConnectionStatus.active.rawValue,
            enrolledAt: first, revokedAt: nil, configSchemaVersion: 1
        ))
        context.insert(GatewayConfigRow(
            key: "external-gateway", appIntentsConnectionID: connectionID,
            nextAuditSequence: 1, auditBytes: 0, compactionFloor: 1, configSchemaVersion: 1
        ))
        var journal: [JournalValue] = []
        for (offset, kind) in [HistoryChangeKindRawV1.insert, .coalesce, .pin, .revise].enumerated() {
            let sequence = UInt64(offset + 1)
            let record = HistoryChangeRecordRow(
                sequence: sequence, changePositionRaw: sequence, changeKindRaw: kind.rawValue,
                affectedItemsBlob: try AffectedItemsBlobCodec.encode([id], for: kind),
                createdAt: first.addingTimeInterval(Double(offset))
            )
            journal.append(JournalValue(record))
            context.insert(record)
        }
        context.insert(JournalConfigRow(
            key: "change-journal", compactionFloorRaw: 0,
            journalBytes: journal.reduce(0) { $0 + UInt64($1.bytes.count) }, configSchemaVersion: 1
        ))
        try context.save()
        let fresh = ModelContext(container)
        let oldRow = try #require(fresh.fetch(FetchDescriptor<HistorySchemaV1.HistoryItemRow>()).first)
        #expect(oldRow.projectionSchemaVersion == 5)
        #expect(Data(oldRow.title.utf8) == Data("after.txt".utf8))
        #expect(oldRow.canonicalBlob == canonicalBlob)
        #expect(oldRow.revisionStateBlob == revisionBlob)
        return Seeded(
            item: HistoryItemReference(id: id, contentVersion: ContentVersion(rawValue: 2)),
            canonicalBlob: canonicalBlob, revisionBlob: revisionBlob,
            signatureBlob: signatureBlob, typeBlob: typeBlob,
            revisionID: revisionID, revisionDate: revisionDate,
            occurrence: CopyOccurrenceSummary(
                firstCopiedAt: first, lastCopiedAt: last, count: 2,
                firstSource: "com.example.first", lastSource: "com.example.last"
            ),
            journal: journal, connectionID: connectionID
        )
    }

    private func verifyFirstPublicOpen(at url: URL, seeded: Seeded) async throws -> HistoryDetails {
        let history = try await WSSupport.openHistory(storeURL: url)
        try await expectTitle("\u{FEFF}after.txt", item: seeded.item, in: history)
        let details = try await history.details(for: seeded.item.id)
        #expect(details.item == seeded.item)
        #expect(details.canonical.map(\.bytes) == [Data(canonicalAddress.utf8)])
        #expect(details.effective.map(\.bytes) == [Data(activeAddress.utf8)])
        #expect(details.revisions.map(\.id) == [seeded.revisionID])
        #expect(details.revisions.map(\.createdAt) == [seeded.revisionDate])
        #expect(details.revisions.map { Data($0.title.utf8) } == [Data("\u{FEFF}after.txt".utf8)])
        #expect(details.occurrence == seeded.occurrence)
        #expect(details.pinnedPosition == 0)
        let payload = try await history.pastePayload(for: seeded.item.id)
        #expect(payload.item == seeded.item)
        #expect(payload.representations == details.effective)
        #expect(try await history.retentionConfiguration() == HistoryRetentionConfiguration(
            maximumUnpinnedItems: 177,
            policies: HistoryRetentionPolicies(
                age: nil, storage: StorageRetention(maxTotalBytes: 1_000_000),
                revisions: RevisionRetention(maxRevisionsPerItem: 10, maxRevisionBytesPerItem: 8_192)
            )
        ))
        let usage = try await history.usage()
        #expect(usage.position.rawValue == 4)
        #expect(usage.itemCount == 1 && usage.pinnedItemCount == 1)
        #expect(usage.canonicalBytes == canonicalAddress.utf8.count)
        #expect(usage.revisionBytes == activeAddress.utf8.count)
        try expectPreservedRows(at: url, seeded: seeded)
        return details
    }

    private func expectTitle(_ title: String, item: HistoryItemReference, in history: SwiftDataHistory) async throws {
        let recent = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(recent.rows.map(\.item) == [item])
        #expect(recent.rows.map { Data($0.title.utf8) } == [Data(title.utf8)])
        let search = try await history.browse(HistoryBrowseRequest(kind: .search(text: title, mode: .exact), limit: 10))
        #expect(search.rows.map(\.item) == [item])
        let hit = try #require(search.rows.first)
        #expect(Data(hit.title.utf8) == Data(title.utf8))
        let presentation = try #require(hit.search)
        #expect(presentation.snippet == nil, "the repaired title itself must match, not the intact body")
    }

    private func expectPreservedRows(at url: URL, seeded: Seeded) throws {
        let context = ModelContext(try WSSupport.makeContainer(storeURL: url))
        let row = try #require(context.fetch(FetchDescriptor<HistoryItemRow>()).first)
        #expect(row.id == seeded.item.id.rawValue && row.contentVersionRaw == 2)
        #expect(row.titleUTF8 == Data("\u{FEFF}after.txt".utf8))
        #expect(row.projectionSchemaVersion == 6)
        #expect(row.canonicalBlob == seeded.canonicalBlob)
        #expect(row.revisionStateBlob == seeded.revisionBlob)
        #expect(row.canonicalSignatureBlob == seeded.signatureBlob)
        #expect(row.effectiveTypeIdentifiersBlob == seeded.typeBlob)
        #expect(Data(row.searchBody.utf8) == Data((activeAddress + "\n/\u{FEFF}after.txt").utf8))
        #expect(row.firstCopiedAt == seeded.occurrence.firstCopiedAt)
        #expect(row.lastCopiedAt == seeded.occurrence.lastCopiedAt)
        #expect(row.copyCount == 2 && row.pinOrdinal == 0)
        #expect(row.firstSource == "com.example.first" && row.lastSource == "com.example.last")
        let bytes = try #require(context.fetch(FetchDescriptor<RetainedBytesRow>()).first)
        #expect(bytes.itemID == row.id && bytes.bytesSchemaVersion == 1)
        #expect(bytes.canonicalBytes == canonicalAddress.utf8.count)
        #expect(bytes.revisionCount == 1 && bytes.revisionBytes == activeAddress.utf8.count)
        let position = try #require(context.fetch(FetchDescriptor<LastChangePositionRow>()).first)
        #expect(position.key == "retained-history" && position.rawValue == 4)
        #expect(position.maximumUnpinnedItems == 177)
        let records = try context.fetch(FetchDescriptor<HistoryChangeRecordRow>(sortBy: [SortDescriptor(\.sequence)]))
        #expect(records.map(JournalValue.init) == seeded.journal)
        let journal = try #require(context.fetch(FetchDescriptor<JournalConfigRow>()).first)
        #expect(journal.key == "change-journal" && journal.configSchemaVersion == 1)
        #expect(journal.compactionFloorRaw == 0)
        #expect(journal.journalBytes == seeded.journal.reduce(0) { $0 + UInt64($1.bytes.count) })
        let gateway = try #require(context.fetch(FetchDescriptor<GatewayConfigRow>()).first)
        #expect(gateway.appIntentsConnectionID == seeded.connectionID)
        #expect(gateway.nextAuditSequence == 1 && gateway.auditBytes == 0 && gateway.compactionFloor == 1)
        let retention = try #require(context.fetch(FetchDescriptor<RetentionExpansionConfigRow>()).first)
        #expect(retention.key == "retention-expansion" && retention.configSchemaVersion == 1)
        #expect(!retention.agePolicyEnabled && retention.ageMaxSeconds == 0)
        #expect(retention.storagePolicyEnabled && retention.storageMaxBytes == 1_000_000)
        #expect(retention.revisionPolicyEnabled && retention.revisionMaxCount == 10 && retention.revisionMaxBytes == 8_192)
    }

    private func expectNewRevisionStored(at url: URL, seeded: Seeded, newestAddress: String) throws {
        let context = ModelContext(try WSSupport.makeContainer(storeURL: url))
        let row = try #require(context.fetch(FetchDescriptor<HistoryItemRow>()).first)
        #expect(row.id == seeded.item.id.rawValue && row.contentVersionRaw == 3)
        #expect(row.titleUTF8 == Data("\u{FEFF}newest.txt".utf8))
        #expect(row.canonicalBlob == seeded.canonicalBlob)
        #expect(row.canonicalSignatureBlob == seeded.signatureBlob)
        let bytes = try #require(context.fetch(FetchDescriptor<RetainedBytesRow>()).first)
        #expect(bytes.revisionCount == 2)
        #expect(bytes.revisionBytes == activeAddress.utf8.count + newestAddress.utf8.count)
        let records = try context.fetch(FetchDescriptor<HistoryChangeRecordRow>(sortBy: [SortDescriptor(\.sequence)]))
        #expect(records.count == 5)
        #expect(records.prefix(4).map(JournalValue.init) == seeded.journal)
        #expect(records.last?.changeKindRaw == HistoryChangeKindRawV1.revise.rawValue)
        #expect(records.last?.changePositionRaw == 5)
    }
}
