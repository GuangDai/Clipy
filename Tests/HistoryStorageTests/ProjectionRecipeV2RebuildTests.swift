/// Projection recipe-v2 public reopen and atomic startup-rebuild proofs.
/// Owning spec: docs/05-authority-kernel.md §13, §15.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData
import Testing
@testable import HistoryStorage

@Suite("Projection recipe v2 startup rebuild")
struct ProjectionRecipeV2RebuildTests {
    private struct LegacyFixture: Sendable {
        let id: HistoryItemID
        let visibleText: String
        let canonicalBytes: [Data]
        let effectiveBytes: [Data]
        let staleTitle: String
        let staleSearchBody: String
    }

    private struct PreparedLegacyRow: Sendable {
        let fixture: LegacyFixture
        let canonicalBlob: Data
        let revisionStateBlob: Data
        let signatureBlob: Data
        let identifiersBlob: Data
        let canonicalBytes: Int
        let revisionCount: Int
        let revisionBytes: Int
        let contentVersionRaw: UInt64
        let copiedAt: Date
    }

    private static func seedLegacyRows(
        at storeURL: URL,
        count: Int,
        corruptLastRevisionState: Bool = false,
        activeRevisionForFirst: Bool = false
    ) async throws -> [LegacyFixture] {
        let preparation = IngestPreparationActor()
        let observedAt = Date(timeIntervalSinceReferenceDate: 700_060_000)
        var fixtures: [LegacyFixture] = []
        fixtures.reserveCapacity(count)
        var preparedRows: [PreparedLegacyRow] = []
        preparedRows.reserveCapacity(count)

        for index in 0..<count {
            let seededID = HistoryItemID(rawValue: UUID(uuid: (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, UInt8(index + 1)
            )))
            let canonicalText = "Canonical sibling \(index)"
            let canonicalHTML = "<h1>CanonicalMarkup\(index)</h1>"
            let canonicalRTF = #"{\rtf1 CanonicalRTF"# + "\(index)}"
            let bundle = try await preparation.prepare(
                WSSupport.textCapture(
                    canonicalText,
                    observedAt: observedAt.addingTimeInterval(Double(index)),
                    source: "com.example.projection-v2",
                    extra: [
                        ("public.html", Array(canonicalHTML.utf8)),
                        ("public.rtf", Array(canonicalRTF.utf8)),
                    ]
                )
            )
            let hasActiveRevision = activeRevisionForFirst && index == 0
            let visibleText = hasActiveRevision
                ? "Active revision sibling \(index)"
                : canonicalText
            let staleTitle = hasActiveRevision
                ? "<h1>LegacyMarkupNeedle\(index)</h1>"
                : canonicalHTML
            let rtfSource = hasActiveRevision
                ? #"{\rtf1 LegacyRTFNeedle"# + "\(index)}"
                : canonicalRTF
            let effectiveBytes = [
                Data(staleTitle.utf8),
                Data(rtfSource.utf8),
                Data(visibleText.utf8),
            ]
            let revisions: [ContentRevision]
            let activeRevisionID: RevisionID?
            if hasActiveRevision {
                let revisionID = RevisionID(rawValue: UUID(uuid: (
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 1, UInt8(index + 1)
                )))
                revisions = [ContentRevision(
                    id: revisionID,
                    createdAt: observedAt.addingTimeInterval(100),
                    content: EffectiveContent(representations: [
                        ContentRepresentation(
                            typeIdentifier: "public.html",
                            bytes: effectiveBytes[0]
                        ),
                        ContentRepresentation(
                            typeIdentifier: "public.rtf",
                            bytes: effectiveBytes[1]
                        ),
                        ContentRepresentation(
                            typeIdentifier: "public.utf8-plain-text",
                            bytes: effectiveBytes[2]
                        ),
                    ])
                )]
                activeRevisionID = revisionID
            } else {
                revisions = []
                activeRevisionID = nil
            }
            let staleSearchBody = [staleTitle, rtfSource, visibleText]
                .joined(separator: "\n")
            let fixture = LegacyFixture(
                id: seededID,
                visibleText: visibleText,
                canonicalBytes: bundle.domain.canonical.representations.map(
                    \.content.bytes
                ),
                effectiveBytes: effectiveBytes,
                staleTitle: staleTitle,
                staleSearchBody: staleSearchBody
            )
            var canonicalBytes = 0
            for entry in bundle.signatureEntries {
                canonicalBytes += entry.byteCount
            }
            fixtures.append(fixture)
            preparedRows.append(PreparedLegacyRow(
                fixture: fixture,
                canonicalBlob: try CanonicalBlobCodec.encode(
                    bundle.domain.canonical
                ),
                revisionStateBlob: try RevisionStateBlobCodec.encode(
                    revisions: revisions,
                    activeRevisionID: activeRevisionID
                ),
                signatureBlob: try SignatureBlobCodec.encode(
                    bundle.signatureEntries
                ),
                identifiersBlob: try EffectiveTypeIdentifiersBlobCodec.encode(
                    bundle.projection.effectiveTypeIdentifiers
                ),
                canonicalBytes: canonicalBytes,
                revisionCount: revisions.count,
                revisionBytes: revisions.reduce(0) { total, revision in
                    revision.content.representations.reduce(total) {
                        $0 + $1.bytes.count
                    }
                },
                contentVersionRaw: hasActiveRevision ? 2 : 1,
                copiedAt: observedAt.addingTimeInterval(Double(index))
            ))
        }

        // No ModelContext exists across the actor suspension above. The raw
        // fixture write is one synchronous, operation-local interval.
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        context.insert(LastChangePositionRow(
            key: HistoryAuthority.positionSingletonKey,
            rawValue: 7,
            maximumUnpinnedItems: 200
        ))
        for (index, prepared) in preparedRows.enumerated() {
            let revisionStateBlob = corruptLastRevisionState && index == count - 1
                ? Data([0xFF])
                : prepared.revisionStateBlob
            context.insert(HistoryItemRow(
                id: prepared.fixture.id.rawValue,
                contentVersionRaw: prepared.contentVersionRaw,
                canonicalBlob: prepared.canonicalBlob,
                revisionStateBlob: revisionStateBlob,
                canonicalSignatureBlob: prepared.signatureBlob,
                projectionSchemaVersion: ContentProjector.legacySchemaVersion,
                title: prepared.fixture.staleTitle,
                searchBody: prepared.fixture.staleSearchBody,
                effectiveTypeIdentifiersBlob: prepared.identifiersBlob,
                firstCopiedAt: observedAt,
                lastCopiedAt: prepared.copiedAt,
                copyCount: 1,
                firstSource: "com.example.projection-v2",
                lastSource: "com.example.projection-v2",
                pinOrdinal: nil
            ))
            context.insert(RetainedBytesRow(
                itemID: prepared.fixture.id.rawValue,
                canonicalBytes: prepared.canonicalBytes,
                revisionCount: prepared.revisionCount,
                revisionBytes: prepared.revisionBytes,
                bytesSchemaVersion: 1
            ))
        }
        try context.save()
        return fixtures
    }

    private static func fetchRow(
        id: HistoryItemID,
        in context: ModelContext
    ) throws -> HistoryItemRow {
        let uuid = id.rawValue
        var descriptor = FetchDescriptor<HistoryItemRow>(
            predicate: #Predicate { $0.id == uuid }
        )
        descriptor.fetchLimit = 2
        let rows = try context.fetch(descriptor)
        return try #require(rows.count == 1 ? rows[0] : nil)
    }

    private static func mutateStoredProjection(
        id: HistoryItemID,
        at storeURL: URL,
        body: (HistoryItemRow) -> Void
    ) throws {
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        let row = try Self.fetchRow(id: id, in: context)
        body(row)
        try context.save()
    }

    @Test("public reopen rebuilds v1 markup projection before browse/search/details")
    func publicReopenRebuildsLegacyProjection() async throws {
        let storeURL = WSSupport.tempStoreURL("projection-recipe-v2-public")
        defer { WSSupport.removeStore(storeURL) }
        let fixtures = try await Self.seedLegacyRows(
            at: storeURL,
            count: 1,
            activeRevisionForFirst: true
        )
        let fixture = try #require(fixtures.first)

        let history = try await SwiftDataHistory.open(configuration:
            HistoryConfiguration(persistence: .persistent(storeURL: storeURL))
        )

        let recent = try await history.browse(HistoryBrowseRequest(
            kind: .recent,
            limit: 10
        ))
        #expect(recent.position.rawValue == 7)
        #expect(recent.rows.map(\.title) == [fixture.visibleText])
        #expect(
            recent.rows.first?.typeIdentifiers
                == ["public.html", "public.rtf", "public.utf8-plain-text"]
        )

        let visibleSearch = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: fixture.visibleText, mode: .exact),
            limit: 10
        ))
        #expect(visibleSearch.rows.map(\.item.id) == [fixture.id])
        let markupSearch = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "LegacyMarkupNeedle0", mode: .exact),
            limit: 10
        ))
        #expect(markupSearch.rows.isEmpty)

        let details = try await history.details(for: fixture.id)
        #expect(details.item.id == fixture.id)
        #expect(
            details.canonical.map(\.typeIdentifier)
                == ["public.html", "public.rtf", "public.utf8-plain-text"]
        )
        #expect(
            details.effective.map(\.typeIdentifier)
                == ["public.html", "public.rtf", "public.utf8-plain-text"]
        )
        #expect(details.canonical.map(\.bytes) == fixture.canonicalBytes)
        #expect(details.effective.map(\.bytes) == fixture.effectiveBytes)
        #expect(details.item.contentVersion.rawValue == 2)
        #expect(details.revisions.count == 1)
        #expect(details.revisions.first?.isActive == true)

        let inspection = try WSSupport.makeContainer(storeURL: storeURL)
        let inspectionContext = ModelContext(inspection)
        let stored = try Self.fetchRow(id: fixture.id, in: inspectionContext)
        #expect(stored.projectionSchemaVersion == 2)
        #expect(stored.title == fixture.visibleText)
        #expect(stored.searchBody == fixture.visibleText)
    }

    @Test("invalid legacy revision source publishes no projection replacement")
    func invalidLegacyRevisionPublishesNoPartialRebuild() async throws {
        let storeURL = WSSupport.tempStoreURL("projection-recipe-v2-invalid")
        defer { WSSupport.removeStore(storeURL) }
        let fixtures = try await Self.seedLegacyRows(
            at: storeURL,
            count: 2,
            corruptLastRevisionState: true
        )

        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            _ = try await SwiftDataHistory.open(configuration:
                HistoryConfiguration(persistence: .persistent(storeURL: storeURL))
            )
        }

        let inspection = try WSSupport.makeContainer(storeURL: storeURL)
        let inspectionContext = ModelContext(inspection)
        for fixture in fixtures {
            let stored = try Self.fetchRow(id: fixture.id, in: inspectionContext)
            #expect(
                stored.projectionSchemaVersion
                    == ContentProjector.legacySchemaVersion
            )
            #expect(stored.title == fixture.staleTitle)
            #expect(stored.searchBody == fixture.staleSearchBody)
        }
    }

    @Test("mixed v1/v2 startup rebuild leaves the existing v2 row untouched")
    func mixedProjectionVersionsRebuildOnlyLegacyRow() async throws {
        let storeURL = WSSupport.tempStoreURL("projection-recipe-v2-mixed")
        defer { WSSupport.removeStore(storeURL) }
        let fixtures = try await Self.seedLegacyRows(at: storeURL, count: 2)
        let existingV2 = fixtures[1]
        try Self.mutateStoredProjection(id: existingV2.id, at: storeURL) { row in
            row.projectionSchemaVersion = ContentProjector.schemaVersion
            row.title = "Existing v2 title"
            row.searchBody = "Existing v2 body"
        }

        _ = try await SwiftDataHistory.open(configuration:
            HistoryConfiguration(persistence: .persistent(storeURL: storeURL))
        )

        let inspection = try WSSupport.makeContainer(storeURL: storeURL)
        let inspectionContext = ModelContext(inspection)
        let rebuilt = try Self.fetchRow(id: fixtures[0].id, in: inspectionContext)
        #expect(rebuilt.projectionSchemaVersion == ContentProjector.schemaVersion)
        #expect(rebuilt.title == fixtures[0].visibleText)
        let untouched = try Self.fetchRow(id: existingV2.id, in: inspectionContext)
        #expect(untouched.projectionSchemaVersion == ContentProjector.schemaVersion)
        #expect(untouched.title == "Existing v2 title")
        #expect(untouched.searchBody == "Existing v2 body")
    }

    @Test("public open rejects an unknown projection tag without replacement")
    func publicOpenRejectsUnknownProjectionVersion() async throws {
        let storeURL = WSSupport.tempStoreURL("projection-recipe-v2-unknown")
        defer { WSSupport.removeStore(storeURL) }
        let fixtures = try await Self.seedLegacyRows(at: storeURL, count: 1)
        let fixture = try #require(fixtures.first)
        try Self.mutateStoredProjection(id: fixture.id, at: storeURL) { row in
            row.projectionSchemaVersion = 9
        }

        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            _ = try await SwiftDataHistory.open(configuration:
                HistoryConfiguration(persistence: .persistent(storeURL: storeURL))
            )
        }

        let inspection = try WSSupport.makeContainer(storeURL: storeURL)
        let inspectionContext = ModelContext(inspection)
        let stored = try Self.fetchRow(id: fixture.id, in: inspectionContext)
        #expect(stored.projectionSchemaVersion == 9)
        #expect(stored.title == fixture.staleTitle)
        #expect(stored.searchBody == fixture.staleSearchBody)
    }

    @Test("transaction interruption rolls back every projection replacement")
    func interruptedTransactionPublishesNoPartialRebuild() async throws {
        let storeURL = WSSupport.tempStoreURL("projection-recipe-v2-interrupt")
        defer { WSSupport.removeStore(storeURL) }
        let fixtures = try await Self.seedLegacyRows(at: storeURL, count: 2)
        let container = try WSSupport.makeContainer(storeURL: storeURL)
        let context = ModelContext(container)
        context.autosaveEnabled = false

        #expect(throws: HistoryFailure.persistence(.transaction)) {
            try ContentProjectionRebuild.rebuildIfNeeded(
                in: context,
                limits: .standard,
                failAfterFirstMutation: true
            )
        }

        let inspection = ModelContext(container)
        for fixture in fixtures {
            let uuid = fixture.id.rawValue
            var descriptor = FetchDescriptor<HistoryItemRow>(
                predicate: #Predicate { $0.id == uuid }
            )
            descriptor.fetchLimit = 2
            let rows = try inspection.fetch(descriptor)
            let stored = try #require(rows.count == 1 ? rows[0] : nil)
            #expect(
                stored.projectionSchemaVersion
                    == ContentProjector.legacySchemaVersion
            )
            #expect(stored.title == fixture.staleTitle)
            #expect(stored.searchBody == fixture.staleSearchBody)
        }
    }
}
