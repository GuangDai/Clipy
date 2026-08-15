import Testing
@testable import HistoryStorage
import SwiftData

/// M1.1 proof: the `HistorySchemaV1: VersionedSchema` anchor is
/// behavior-preserving — it names the shipped v1 schema without changing the
/// `v1Schema` value, the model set, or any row (`V2-roadmap` §5 M1.1; v1
/// `05` §3). Expected values below come from the v1 spec's model set
/// (`05` §3: exactly `HistoryItemRow` + `LastChangePositionRow`), not from
/// the anchor's own definition.
@Suite("HistorySchemaV1 anchor (M1.1)")
struct HistorySchemaAnchorTests {

    @Test("versionIdentifier names the shipped v1 schema as 1.0.0")
    func versionIdentifierIsOne() {
        #expect(HistorySchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }

    @Test("the anchor's model set is exactly the v1 rows, unordered")
    func modelSetMatchesV1Rows() {
        let anchored = Set(HistorySchemaV1.models.map { "\($0)" })
        let v1Rows: Set<String> = [
            "\(HistoryItemRow.self)",
            "\(LastChangePositionRow.self)"
        ]
        #expect(anchored == v1Rows)
        #expect(HistorySchemaV1.models.count == 2)
    }

    @Test("Schema(versionedSchema:) resolves the same entities as the frozen v1Schema value")
    func anchorSchemaEntitiesMatchV1SchemaValue() {
        let fromAnchor = Schema(versionedSchema: HistorySchemaV1.self)
        let anchorEntities = Set(fromAnchor.entities.map { "\($0.name)" })
        let v1Entities = Set(v1Schema.entities.map { "\($0.name)" })
        #expect(anchorEntities == v1Entities)
        #expect(!anchorEntities.isEmpty)
    }

    @Test("a container built from the anchor opens the same v1 store shape as v1Schema")
    func anchorContainerOpensV1Store() throws {
        // In-memory per the repo's persistence-test rule (AGENTS §6): the real
        // SwiftData store, no fake writer. Both containers are fresh v1
        // stores; the proof is that the anchor registers the same v1 entities
        // end to end (open + fetch of the singleton row shape), not merely
        // as static metadata.
        let anchorContainer = try ModelContainer(
            for: Schema(versionedSchema: HistorySchemaV1.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let v1Container = try ModelContainer(
            for: v1Schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let anchorContext = ModelContext(anchorContainer)
        let v1Context = ModelContext(v1Container)

        // The v1 singleton row (05 §3.2) is constructible and fetchable
        // through the anchor-registered schema with identical field surface.
        let row = LastChangePositionRow(
            key: "retained-history", rawValue: 0, maximumUnpinnedItems: 100
        )
        anchorContext.insert(row)
        let item = HistoryItemRow(
            id: UUID(), contentVersionRaw: 1,
            canonicalBlob: Data([0]), revisionStateBlob: Data([0]),
            canonicalSignatureBlob: Data([0]),
            projectionSchemaVersion: 1, title: "t", searchBody: "b",
            effectiveTypeIdentifiersBlob: Data([0]),
            firstCopiedAt: Date(timeIntervalSince1970: 1),
            lastCopiedAt: Date(timeIntervalSince1970: 1),
            copyCount: 1, firstSource: nil, lastSource: nil, pinOrdinal: nil
        )
        v1Context.insert(item)
        try anchorContext.save()
        try v1Context.save()

        #expect(try anchorContext.fetchCount(FetchDescriptor<LastChangePositionRow>()) == 1)
        #expect(try v1Context.fetchCount(FetchDescriptor<HistoryItemRow>()) == 1)
        #expect(row.maximumUnpinnedItems == 100)
        #expect(item.contentVersionRaw == 1)
    }
}
