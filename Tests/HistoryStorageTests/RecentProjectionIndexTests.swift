import Foundation
import HistoryCore
@testable import HistoryStorage
import Testing

struct RecentProjectionIndexTests {
    @Test(arguments: [false, true])
    func persistentReopenPreservesBytesPositionAndCursorRules(indexMissing: Bool) async throws {
        let storeURL = WSSupport.tempStoreURL("recent-projection-reopen")
        defer { WSSupport.removeStore(storeURL) }
        let fixture = try await preparePersistentFixture(at: storeURL, indexMissing: indexMissing)
        // The preparation helper returns only immutable values, releasing the
        // first public owner before this real persistent open.
        let reopened = try await WSSupport.openHistory(storeURL: storeURL)
        #expect(try await reopened.authority.hasRecentProjectionIndex())
        #expect(try await reopened.usage() == fixture.usage)
        #expect(try WSSupport.fetchRows(WSSupport.makeDatabase(storeURL: storeURL)) == fixture.storedRows)
        let first = try await reopened.browse(.init(kind: .recent, limit: 2))
        #expect(first.rows == fixture.first.rows)
        #expect(first.position == fixture.first.position)
        let oldCursor = try #require(fixture.first.next)
        await #expect(throws: HistoryFailure.snapshotExpired(current: fixture.usage.position)) {
            try await reopened.browse(.init(kind: .recent, limit: 2, cursor: oldCursor))
        }
        let newCursor = try #require(first.next)
        let second = try await reopened.browse(.init(kind: .recent, limit: 2, cursor: newCursor))
        #expect(second.rows == fixture.second.rows)
        let previous = try #require(second.previous)
        #expect(try await reopened.browse(.init(kind: .recent, limit: 2, cursor: previous)) == first)
        for expected in fixture.payloads {
            let actual = try await reopened.pastePayload(for: expected.item.id)
            #expect(actual == expected)
            #expect(actual.representations.map { Data($0.typeIdentifier.utf8) }
                    == expected.representations.map { Data($0.typeIdentifier.utf8) })
        }
    }

    private func preparePersistentFixture(at storeURL: URL, indexMissing: Bool) async throws -> RecentProjectionReopenFixture {
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        #expect(try await history.authority.hasRecentProjectionIndex())
        var payloads: [PastePayload] = []
        for (index, types) in [try boundaryTypes(blobBytes: 1_024), try boundaryTypes(blobBytes: 1_025), largeMetadataTypes()].enumerated() {
            let reference = try await insertMetadataCapture(history, types: types, index: index)
            payloads.append(try await history.pastePayload(for: reference.id))
        }
        await history.authority.waitForBlobCleanup()
        let first = try await history.browse(.init(kind: .recent, limit: 2))
        let next = try #require(first.next)
        let second = try await history.browse(.init(kind: .recent, limit: 2, cursor: next))
        let usage = try await history.usage()
        let storedRows = try WSSupport.fetchRows(WSSupport.makeDatabase(storeURL: storeURL))
        if indexMissing {
            // Only this private fixture loses its rebuildable optimizer
            // index. Business rows and the current owner's cursor stay intact.
            try await history.authority.withTestDatabase { owner in
                try owner.database.execute("DROP INDEX history_items_recent_projection")
            }
            #expect(try await history.authority.hasRecentProjectionIndex() == false)
            #expect(try await history.usage() == usage)
            #expect(try await history.browse(.init(kind: .recent, limit: 2, cursor: next)) == second)
        }
        return RecentProjectionReopenFixture(usage: usage, storedRows: storedRows,
                                             first: first, second: second, payloads: payloads)
    }

    @Test func boundedExpressionPreservesRealCodecMetadataAndBoundaryPages() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .temporary, initialMaximumUnpinnedItems: nil
        ))
        let inlineTypes = try boundaryTypes(blobBytes: 1_024)
        let fallbackTypes = try boundaryTypes(blobBytes: 1_025)
        let largeTypes = largeMetadataTypes()
        let largeBlobBytes = try EffectiveTypeIdentifiersBlobCodec.encode(largeTypes).count
        try #require(largeBlobBytes > 1_025)
        let types = [inlineTypes, fallbackTypes, largeTypes]
        var references: [HistoryItemReference] = []
        for (index, identifiers) in types.enumerated() {
            references.append(try await insertMetadataCapture(history, types: identifiers, index: index))
        }
        let request = HistoryBrowseRequest(kind: .recent, limit: 3)
        let original = try await history.browse(request)
        #expect(try await history.authority.hasRecentProjectionIndex())
        for (index, reference) in references.enumerated() {
            let blob = try await history.authority.recentProjectionTypes(for: reference.id)
            let expected = types[index].map { Data($0.utf8) }
            #expect(try EffectiveTypeIdentifiersBlobCodec.decode(blob).map { Data($0.utf8) } == expected)
            #expect(try await history.representationMetadata(for: reference).map { Data($0.typeIdentifier.utf8) } == expected)
            let row = try #require(original.rows.first { $0.item == reference })
            #expect(row.typeIdentifiers.map { Data($0.utf8) } == expected)
            let projected = try await history.authority.recentProjectionInlineTypes(for: reference.id)
            if index == 0 {
                #expect(blob.count == 1_024)
                #expect(projected == blob)
            } else {
                #expect(blob.count == (index == 1 ? 1_025 : largeBlobBytes))
                #expect(projected == nil)
            }
        }
        let position = original.position
        #expect(try await history.browse(request) == original)
        try await history.authority.verifyRecentProjectionRows(original.rows)
        let inline = await history.measureRecentPage(metadataRequest(at: 0))
        let fallback = await history.measureRecentPage(metadataRequest(at: 1))
        #expect(try inline.result.get().rows.map(\.item) == [references[0]])
        #expect(try fallback.result.get().rows.map(\.item) == [references[1]])
        // Both one-row requests use the same page shape. The additional
        // statement is the required original-BLOB primary-key fallback.
        #expect(fallback.metrics.statementCount == inline.metrics.statementCount + 1)
        #expect(fallback.metrics.rowsDecoded == inline.metrics.rowsDecoded)
        #expect(fallback.metrics.virtualMachineSteps > 0)
        #expect(try await history.usage().position == position)
    }

    @Test func fallbackRejectsInvalidOriginalMetadataAndKeepsPartialWork() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .temporary, initialMaximumUnpinnedItems: nil
        ))
        let reference = try await insertMetadataCapture(history, types: boundaryTypes(blobBytes: 1_025), index: 0)
        let request = metadataRequest(at: 0)
        let successful = await history.measureRecentPage(request)
        let page = try successful.result.get()
        let original = try await history.authority.recentProjectionTypes(for: reference.id)
        // The existing NOT NULL schema rejects a stored NULL, even though a
        // NULL projected expression is a legitimate fallback sentinel.
        await #expect(throws: SQLiteFailure.self) {
            try await history.authority.replaceRecentProjectionTypes(for: reference.id, value: .null)
        }
        #expect(try await history.browse(request) == page)
        let invalidValues: [SQLiteValue] = [
            .blob(Data([0])), .blob(Data(repeating: 0, count: 1_025)),
            .text(String(repeating: "x", count: 1_025)),
            .blob(Data(repeating: 0, count: EffectiveTypeIdentifiersBlobCodec.maximumBlobBytes() + 1)),
        ]
        for value in invalidValues {
            try await history.authority.replaceRecentProjectionTypes(for: reference.id, value: value)
            let failed = await history.measureRecentPage(request)
            #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) { try failed.result.get() }
            await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) { try await history.browse(request) }
            #expect(failed.metrics.virtualMachineSteps > 0)
            let requiresFallback: Bool
            if case .blob(let bytes) = value, bytes.count == 1 { requiresFallback = false }
            else { requiresFallback = true }
            #expect(failed.metrics.statementCount == successful.metrics.statementCount - (requiresFallback ? 0 : 1))
            try await history.authority.replaceRecentProjectionTypes(for: reference.id, value: .blob(original))
            let restored = await history.measureRecentPage(request)
            #expect(try restored.result.get() == page)
            #expect(restored.metrics.statementCount == successful.metrics.statementCount)
        }
    }

    @Test func fallbackRejectsNoncanonicalIDBeforePrimaryKeyRead() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(
            persistence: .temporary, initialMaximumUnpinnedItems: nil
        ))
        let reference = try await insertMetadataCapture(history, types: boundaryTypes(blobBytes: 1_025), index: 0)
        let request = metadataRequest(at: 0)
        let successful = await history.measureRecentPage(request)
        _ = try successful.result.get()
        // This is a valid UUID spelling with the wrong canonical case. It
        // cannot be normalized and used to retrieve some other item's types.
        try await history.authority.replaceRecentProjectionID(reference.id, with: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        let failed = await history.measureRecentPage(request)
        #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) { try failed.result.get() }
        #expect(failed.metrics.virtualMachineSteps > 0)
        #expect(failed.metrics.rowsDecoded == 0)
        #expect(failed.metrics.statementCount == successful.metrics.statementCount - 1)
    }

    private func boundaryTypes(blobBytes: Int) throws -> [String] {
        let first = "com.clipy.boundary.a." + String(repeating: "x", count: 512 - "com.clipy.boundary.a.".utf8.count)
        let secondPrefix = "com.clipy.boundary.b."
        let overhead = try EffectiveTypeIdentifiersBlobCodec.encode([first, secondPrefix]).count
        let padding = blobBytes - overhead
        try #require(padding >= 0 && secondPrefix.utf8.count + padding <= 512)
        let identifiers = [first, secondPrefix + String(repeating: "x", count: padding)]
        let blob = try EffectiveTypeIdentifiersBlobCodec.encode(identifiers)
        try #require(blob.count == blobBytes)
        try #require(try EffectiveTypeIdentifiersBlobCodec.decode(blob) == identifiers)
        return identifiers
    }

    private func largeMetadataTypes() -> [String] {
        (0..<HistoryLimits.standard.maximumRepresentationsPerCaptureOrRevision).map { index in
            let prefix = "com.clipy.large.\(index).e\u{301}."
            return prefix + String(repeating: "x", count: 512 - prefix.utf8.count)
        }.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    private func insertMetadataCapture(_ history: SQLiteHistory, types: [String], index: Int) async throws -> HistoryItemReference {
        let capture = ClipboardCapture(
            representations: types.enumerated().map {
                CapturedRepresentation(typeIdentifier: $0.element, bytes: Data("metadata-\(index)-\($0.offset)".utf8))
            },
            origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(index))
        )
        guard case .committed(let commit) = try await history.perform(.capture(capture)),
              case .inserted(let reference) = commit.outcome else {
            throw RecentProjectionFixtureFailure.unexpectedMutation
        }
        return reference
    }

    private func metadataRequest(at index: Int) -> HistoryBrowseRequest {
        HistoryBrowseRequest(kind: .recent, limit: 3, filter: .init(
            copiedAfter: Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(index)),
            copiedBefore: Date(timeIntervalSinceReferenceDate: 600_000_001 + Double(index))
        ))
    }
}

private enum RecentProjectionFixtureFailure: Error {
    case notDisposable, unexpectedPage, unexpectedMutation
}

private struct RecentProjectionReopenFixture: Sendable {
    let usage: HistoryUsage
    let storedRows: [WSSupport.StoredItem]
    let first: HistoryPage
    let second: HistoryPage
    let payloads: [PastePayload]
}

private extension HistoryAuthority {
    func hasRecentProjectionIndex() throws -> Bool {
        let row = try database.prepare("SELECT 1 FROM sqlite_master WHERE type='index' AND name='history_items_recent_projection'")
        defer { row.finalize() }
        return try row.step()
    }

    func recentProjectionTypes(for id: HistoryItemID) throws -> Data {
        let row = try database.prepare("SELECT effectiveTypeIdentifiersBlob FROM history_items WHERE id=?",
                                       bindings: [.text(id.rawValue.uuidString)])
        defer { row.finalize() }
        guard try row.step() else { throw RecentProjectionFixtureFailure.unexpectedPage }
        return try row.blob(at: 0)
    }

    func recentProjectionInlineTypes(for id: HistoryItemID) throws -> Data? {
        let row = try database.prepare("SELECT \(ScalarReadRow.recentInlineTypesExpression) FROM history_items WHERE id=?",
                                       bindings: [.text(id.rawValue.uuidString)])
        defer { row.finalize() }
        guard try row.step() else { throw RecentProjectionFixtureFailure.unexpectedPage }
        return try row.optionalBlob(at: 0)
    }

    func replaceRecentProjectionTypes(for id: HistoryItemID, value: SQLiteValue) throws {
        guard storeLocation.ownedDirectoryURL != storeLocation.rootURL else {
            throw RecentProjectionFixtureFailure.notDisposable
        }
        try database.execute("UPDATE history_items SET effectiveTypeIdentifiersBlob=? WHERE id=?",
                             bindings: [value, .text(id.rawValue.uuidString)])
    }

    func replaceRecentProjectionID(_ id: HistoryItemID, with name: String) throws {
        guard storeLocation.ownedDirectoryURL != storeLocation.rootURL else {
            throw RecentProjectionFixtureFailure.notDisposable
        }
        try database.execute("PRAGMA foreign_keys=OFF")
        defer { try? database.execute("PRAGMA foreign_keys=ON") }
        try database.execute("UPDATE history_items SET id=? WHERE id=?",
                             bindings: [.text(name), .text(id.rawValue.uuidString)])
    }

    func verifyRecentProjectionRows(_ rows: [HistoryRow]) throws {
        try database.readTransaction(checkingCancellation: true) {
            guard let first = rows.first else { throw RecentProjectionFixtureFailure.unexpectedPage }
            let statement = try database.prepare("""
                SELECT \(ScalarReadRow.columns) FROM history_items
                INDEXED BY sqlite_autoindex_history_items_1 WHERE id=?
                """, bindings: [.text(first.item.id.rawValue.uuidString)])
            defer { statement.finalize() }
            for (index, row) in rows.enumerated() {
                try Task.checkCancellation()
                if index > 0 { try statement.reset(bindings: [.text(row.item.id.rawValue.uuidString)]) }
                guard try statement.step(), try ScalarReadRow(statement, limits: limits).toHistoryRow(limits: limits) == row else {
                    throw RecentProjectionFixtureFailure.unexpectedPage
                }
            }
        }
    }
}
