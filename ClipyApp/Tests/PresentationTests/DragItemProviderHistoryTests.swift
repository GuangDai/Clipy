/// Real capture/revision/removal through the public provider callback. A drag
/// reads current-by-ID once, then keeps that payload across format requests
/// (03b §9 / 04 §8 DEC-PASTE-REFERENCE).
import Foundation
@testable import HistoryCore
@testable import HistoryStorage
@testable import ClipyApp
import Testing

@MainActor
struct DragItemProviderHistoryTests {
    @Test func hiddenTypeFailsWhileNULAndOpaqueSiblingsKeepTheFirstCurrentPayload() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let original = try await Self.capture(history)
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.first?.item == original })
        let provider = state.dragItemProvider(for: original)
        #expect(Set(provider.registeredTypeIdentifiers) == Set(Self.types))

        let firstRevision = try await Self.revise(
            history, reference: original, hidden: true,
            nulBytes: Data([0x00]), opaqueBytes: Data([0xFF, 0x00, 0x80])
        )
        // No provider data has been requested yet. Its initially advertised
        // text is absent from the current payload, not an empty success.
        let missing = await Self.load(provider, type: Self.types[0])
        #expect(missing.bytes == nil)
        #expect(missing.errorDomain == NSItemProvider.errorDomain)
        #expect(missing.errorCode == NSItemProvider.ErrorCode.itemUnavailableError.rawValue)
        let nul = await Self.load(provider, type: Self.types[1])
        #expect(nul.bytes == Data([0x00]))
        #expect(nul.errorDomain == nil)

        let secondRevision = try await Self.revise(
            history, reference: firstRevision, hidden: false,
            nulBytes: Data([0x01]), opaqueBytes: Data([0x02, 0x03])
        )
        let current = try await history.pastePayload(for: original.id)
        #expect(current.item == secondRevision)
        #expect(current.representations.first { $0.typeIdentifier == Self.types[2] }?.bytes == Data([0x02, 0x03]))
        state.deactivate()

        // A previously unrequested format still belongs to the first read,
        // even after another revision and after the panel has closed.
        let opaque = await Self.load(provider, type: Self.types[2])
        #expect(opaque.bytes == Data([0xFF, 0x00, 0x80]))
        #expect(opaque.errorDomain == nil)
        let stillMissing = await Self.load(provider, type: Self.types[0])
        #expect(stillMissing.bytes == nil)
        #expect(stillMissing.errorDomain != nil)
        #expect(state.failure == nil)
    }

    @Test func removedItemFailsEveryAdvertisedFormatWithoutChangingThePanelBanner() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let original = try await Self.capture(history)
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.first?.item == original })
        let provider = state.dragItemProvider(for: original)
        _ = try await history.perform(.remove(original.id))

        for type in Self.types {
            let result = await Self.load(provider, type: type)
            #expect(result.bytes == nil)
            #expect(result.errorDomain != nil)
        }
        #expect(state.failure == nil)
    }

    @Test func multiItemDragRejectsInsteadOfExportingOnlyTheFirstItemsBytes() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: Self.types[0], bytes: Data("first".utf8)),
                CapturedRepresentation(typeIdentifier: Self.types[0], bytes: Data("second".utf8), pasteboardItemIndex: 1)
            ],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSince1970: 1)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            Issue.record("Expected the complete multi-item capture")
            return
        }
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.first?.item == item })
        let result = await Self.load(state.dragItemProvider(for: item), type: Self.types[0])
        #expect(result.bytes == nil)
        #expect(result.errorDomain == NSItemProvider.errorDomain)
        #expect(result.errorCode == NSItemProvider.ErrorCode.itemUnavailableError.rawValue)
        #expect(state.failure == nil)
    }

    private static let types = [
        "public.utf8-plain-text", "com.clipy.tests.drag-nul", "com.clipy.tests.drag-opaque",
    ]

    private static func capture(_ history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: types[0], bytes: Data("original text".utf8)),
                CapturedRepresentation(typeIdentifier: types[1], bytes: Data([0x00])),
                CapturedRepresentation(typeIdentifier: types[2], bytes: Data([0x7F])),
            ],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_094_000)
        )))
        let reference: HistoryItemReference?
        if case let .committed(commit) = receipt, case let .inserted(item) = commit.outcome {
            reference = item
        } else {
            reference = nil
        }
        return try #require(reference)
    }

    private static func revise(
        _ history: SQLiteHistory,
        reference: HistoryItemReference,
        hidden: Bool,
        nulBytes: Data,
        opaqueBytes: Data
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.revise(RevisionRequest(
            itemID: reference.id, expected: reference.contentVersion,
            intent: .replace(RevisionDraft(decisions: [
                RevisionDecision(typeIdentifier: types[0], action: hidden ? .hide : .inheritCanonical),
                RevisionDecision(typeIdentifier: types[1], action: .replace(bytes: nulBytes)),
                RevisionDecision(typeIdentifier: types[2], action: .replace(bytes: opaqueBytes)),
            ]))
        )))
        let revised: HistoryItemReference?
        if case let .committed(commit) = receipt, case let .revised(item) = commit.outcome {
            revised = item
        } else {
            revised = nil
        }
        return try #require(revised)
    }

    private static func load(_ provider: NSItemProvider, type: String) async -> LoadResult {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { bytes, error in
                let platformError = error as NSError?
                continuation.resume(returning: LoadResult(
                    bytes: bytes, errorDomain: platformError?.domain, errorCode: platformError?.code
                ))
            }
        }
    }

    private struct LoadResult: Sendable {
        let bytes: Data?
        let errorDomain: String?
        let errorCode: Int?
    }
}
