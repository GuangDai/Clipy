/// Real SQLite commits and rollback, verified by an independent connection.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct TransactionBoundaryProofTests {
    @Test func successfulCaptureCommitsRowsContentAndPositionTogether() async throws {
        let url = WSSupport.tempStoreURL("sqlite-transaction-success")
        defer { WSSupport.removeStore(url) }
        let history = try await WSSupport.openHistory(storeURL: url)
        let receipt = try await history.perform(.capture(WSSupport.textCapture("committed text", observedAt: Date(timeIntervalSinceReferenceDate: 1000))))
        guard case let .committed(commit) = receipt, case let .inserted(item) = commit.outcome else { Issue.record("expected insert"); return }
        let snapshot = try TransactionStoreSnapshot.read(from: url)
        #expect(snapshot.items.count == 1)
        #expect(snapshot.items.first?.id == item.id.rawValue)
        #expect(snapshot.items.first?.contentVersionRaw == 1)
        #expect(snapshot.items.first?.titleUTF8 == Data("committed text".utf8))
        #expect(snapshot.items.first?.copyCount == 1)
        #expect(snapshot.contents.count == 1 && snapshot.representations.count == 1)
        #expect(snapshot.positions.first?.rawValue == commit.position.rawValue)
        #expect(snapshot.positions.first?.retainedItemCount == 1)
        let reader = try WSSupport.makeDatabase(storeURL: url)
        let content = try WSSupport.fetchCanonical(itemID: item.id.rawValue, in: reader)
        #expect(content.representations.map(\.content.bytes) == [Data("committed text".utf8)])
    }

    @Test func failedTransactionPreservesEveryStoredValueAndPublishesNothing() async throws {
        let url = WSSupport.tempStoreURL("sqlite-transaction-rollback")
        defer { WSSupport.removeStore(url) }
        let history = try await WSSupport.openHistory(storeURL: url)
        _ = try await history.perform(.capture(WSSupport.textCapture("retained seed")))
        let before = try TransactionStoreSnapshot.read(from: url)
        let prepared = try await IngestPreparationActor().prepare(WSSupport.textCapture("must not persist"))
        let registration = await history.authority.registerInvalidationSubscriber()
        await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
        await #expect(throws: HistoryFailure.persistence(.transaction)) { try await history.authority.commitCapture(prepared) }
        #expect(try TransactionStoreSnapshot.read(from: url) == before)
        let page = try await history.browse(.init(kind: .recent, limit: 10))
        #expect(page.position.rawValue == 1 && page.rows.map(\.title) == ["retained seed"])
        let item = try #require(page.rows.first?.item)
        #expect(try await history.pastePayload(for: item.id).representations.map(\.bytes) == [Data("retained seed".utf8)])
        await #expect(throws: HistoryFailure.notFound(prepared.domain.candidateID)) { try await history.details(for: prepared.domain.candidateID) }
        await history.authority.unregisterInvalidationSubscriber(registration.subscription)
        var publications = 0
        for try await _ in registration.stream { publications += 1 }
        #expect(publications == 0)
    }

    @Test func failureInjectionIsOneShotAndRecoveryUsesTheNextPosition() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        _ = try await history.perform(.capture(WSSupport.textCapture("first")))
        let prepared = try await IngestPreparationActor().prepare(WSSupport.textCapture("second"))
        await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
        await #expect(throws: HistoryFailure.persistence(.transaction)) { try await history.authority.commitCapture(prepared) }
        let recovered = try await history.authority.commitCapture(prepared)
        guard case let .committed(commit) = recovered, case .inserted = commit.outcome else { Issue.record("expected recovered insert"); return }
        #expect(commit.position.rawValue == 2)
        let page = try await history.browse(.init(kind: .recent, limit: 10))
        #expect(Set(page.rows.map(\.title)) == ["first", "second"])
        #expect(page.position == commit.position)
    }

    @Test func outOfSpaceRollsBackAndKeepsTheOldStateReadable() async throws {
        let url = WSSupport.tempStoreURL("sqlite-transaction-full")
        defer { WSSupport.removeStore(url) }
        let history = try await WSSupport.openHistory(storeURL: url)
        _ = try await history.perform(.capture(WSSupport.textCapture("disk seed")))
        let before = try TransactionStoreSnapshot.read(from: url)
        let registration = await history.authority.registerInvalidationSubscriber()
        await history.authority.setTransactionFailureInjection(.insufficientDiskSpace)
        await #expect(throws: HistoryFailure.temporarilyUnavailable(.insufficientDiskSpace)) {
            try await history.perform(.capture(WSSupport.textCapture("disk rejected")))
        }
        #expect(try TransactionStoreSnapshot.read(from: url) == before)
        await history.authority.unregisterInvalidationSubscriber(registration.subscription)
        var publications = 0
        for try await _ in registration.stream { publications += 1 }
        #expect(publications == 0)
        let page = try await history.browse(.init(kind: .recent, limit: 10))
        #expect(page.position.rawValue == 1 && page.rows.map(\.title) == ["disk seed"])
    }
}

struct TransactionPositionSnapshot: Equatable, Sendable {
    let key: String
    let rawValue: UInt64
    let maximumUnpinnedItems: Int
    let retainedItemCount: Int
    let pinnedItemCount: Int
    let canonicalBytes: Int
    let revisionBytes: Int
}

struct TransactionConfigSnapshot: Equatable, Sendable {
    let key: String
    let ageMaxSeconds: Double?
    let storageMaxBytes: Int?
    let revisionMaxCount: Int?
    let revisionMaxBytes: Int?
}

/// Small test-store rollback oracle: actual metadata columns, representation
/// references/inline bytes and referenced immutable files, compared directly.
/// Orphan files from pre-commit publication are intentionally outside the
/// committed state; the blob store's cleanup tests cover their lifetime.
struct TransactionStoreSnapshot: Equatable, Sendable {
    let items: [WSSupport.StoredItem]
    let contents: [[SQLiteValue]]
    let representations: [[SQLiteValue]]
    let positions: [TransactionPositionSnapshot]
    let configs: [TransactionConfigSnapshot]
    let referencedBlobs: [UUID: Data]

    static func read(from url: URL) throws -> Self {
        let database = try SQLiteDatabase(url: url, readOnly: true)
        return try database.readTransaction {
            let items = try WSSupport.fetchRows(database)
            let contentQuery = try database.prepare("SELECT id, itemID, revisionOrdinal, createdAt, titleUTF8, contentByteCount, representationCount FROM contents ORDER BY id")
            defer { contentQuery.finalize() }
            var contents: [[SQLiteValue]] = []
            while try contentQuery.step() {
                contents.append(try [.text(contentQuery.text(at: 0)), .text(contentQuery.text(at: 1)),
                    .integer(contentQuery.integer(at: 2)), .real(contentQuery.real(at: 3)), .blob(contentQuery.blob(at: 4)),
                    .integer(contentQuery.integer(at: 5)), .integer(contentQuery.integer(at: 6))])
            }
            let representationQuery = try database.prepare("SELECT contentID, ordinal, exactType, typeKey, byteCount, fingerprint, inlineBytes, blobID FROM representations ORDER BY contentID, ordinal")
            defer { representationQuery.finalize() }
            var representations: [[SQLiteValue]] = []
            var blobs: [UUID: Data] = [:]
            while try representationQuery.step() {
                let fingerprint = try representationQuery.optionalBlob(at: 5)
                let inline = try representationQuery.optionalBlob(at: 6)
                let blob = try representationQuery.optionalText(at: 7)
                representations.append(try [.text(representationQuery.text(at: 0)), .integer(representationQuery.integer(at: 1)),
                    .text(representationQuery.text(at: 2)), .text(representationQuery.text(at: 3)), .integer(representationQuery.integer(at: 4)),
                    fingerprint.map(SQLiteValue.blob) ?? .null, inline.map(SQLiteValue.blob) ?? .null, blob.map(SQLiteValue.text) ?? .null])
                if let blob {
                    let id = try #require(UUID(uuidString: blob))
                    let path = url.deletingLastPathComponent().appendingPathComponent("blobs/\(id.uuidString.prefix(2))/\(id.uuidString).blob")
                    blobs[id] = try Data(contentsOf: path, options: .mappedIfSafe)
                }
            }
            let positionQuery = try database.prepare("SELECT key, changePosition, maximumUnpinnedItems, retainedItemCount, pinnedItemCount, canonicalBytes, revisionBytes FROM history_state ORDER BY key")
            defer { positionQuery.finalize() }
            var positions: [TransactionPositionSnapshot] = []
            while try positionQuery.step() {
                positions.append(try .init(key: positionQuery.text(at: 0), rawValue: sqliteUInt64(positionQuery.blob(at: 1)),
                    maximumUnpinnedItems: Int(positionQuery.integer(at: 2)), retainedItemCount: Int(positionQuery.integer(at: 3)),
                    pinnedItemCount: Int(positionQuery.integer(at: 4)), canonicalBytes: Int(positionQuery.integer(at: 5)),
                    revisionBytes: Int(positionQuery.integer(at: 6))))
            }
            let policyQuery = try database.prepare("SELECT key, ageMaxSeconds, storageMaxBytes, revisionMaxCount, revisionMaxBytes FROM retention_policies ORDER BY key")
            defer { policyQuery.finalize() }
            var configs: [TransactionConfigSnapshot] = []
            while try policyQuery.step() {
                configs.append(try .init(key: policyQuery.text(at: 0),
                    ageMaxSeconds: policyQuery.isNull(at: 1) ? nil : policyQuery.real(at: 1),
                    storageMaxBytes: policyQuery.isNull(at: 2) ? nil : Int(policyQuery.integer(at: 2)),
                    revisionMaxCount: policyQuery.isNull(at: 3) ? nil : Int(policyQuery.integer(at: 3)),
                    revisionMaxBytes: policyQuery.isNull(at: 4) ? nil : Int(policyQuery.integer(at: 4))))
            }
            return Self(items: items, contents: contents, representations: representations, positions: positions, configs: configs, referencedBlobs: blobs)
        }
    }
}
