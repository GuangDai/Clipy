/// Drag-out UI behavior through the real NSItemProvider callback API.
/// Scripted History replies control the async read/version ordering; these
/// tests do not stand in for storage capture/revision/paste semantic tests
/// (01 §4/§5.6; 03b §9 / 04 §8 DEC-PASTE-REFERENCE).
import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct DragItemProviderTests {
    @Test
    func everyAdvertisedRepresentationLoadsItsExactBytes() async throws {
        let reference = Self.reference(version: 1)
        let representations = [
            HistoryRepresentation(typeIdentifier: "public.url", bytes: Data("https://example.invalid/".utf8)),
            HistoryRepresentation(typeIdentifier: "com.clipy.tests.private", bytes: Data([0x00, 0xFF])),
            HistoryRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("visible text".utf8)),
            HistoryRepresentation(typeIdentifier: "public.utf16-plain-text", bytes: Data([0x41, 0x00])),
            HistoryRepresentation(typeIdentifier: "dyn.clipy-drag", bytes: Data([0x80, 0x00, 0xFE])),
        ]
        let payload = PastePayload(item: reference, representations: representations, lineageHint: reference.id)
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: [Self.row(reference, types: representations.map(\.typeIdentifier))], next: nil),
            pastePayloadRead: { _ in payload }
        )
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 1 })
        let provider = state.dragItemProvider(for: reference)
        #expect(provider.registeredTypeIdentifiers == [
            "public.utf8-plain-text", "public.url", "com.clipy.tests.private",
            "public.utf16-plain-text", "dyn.clipy-drag",
        ])

        for representation in representations {
            let result = await Self.load(provider, type: representation.typeIdentifier)
            #expect(result.bytes == representation.bytes)
            #expect(!result.failed)
        }
        #expect(state.failure == nil)
        await history.finishObservation()
    }

    @Test
    func inProgressDragCanFinishAfterPanelDeactivation() async throws {
        let reference = Self.reference(version: 1)
        let payload = Self.textPayload(reference, text: "chosen before panel close")
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: [Self.row(reference)], next: nil),
            pastePayloadRead: { _ in payload }
        )
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 1 })
        let provider = state.dragItemProvider(for: reference)
        state.deactivate()

        let result = await Self.load(provider)
        #expect(result.bytes == Data("chosen before panel close".utf8))
        #expect(!result.failed)
        await history.finishObservation()
    }

    @Test(arguments: ["revised", "removed", "hidden-type"])
    func payloadReadUsesCurrentEffectiveContentAfterDragBegins(change: String) async throws {
        let original = Self.reference(version: 1)
        let revised = Self.reference(version: 2)
        let read = PausedDragRead()
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: [Self.row(original)], next: nil),
            pastePayloadRead: { _ in try await read.value() }
        )
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 1 })
        let provider = state.dragItemProvider(for: original)
        let loading = Task { await Self.load(provider) }
        #expect(await pollUntil { await read.isWaiting })

        // The gesture's displayed reference admits the drag. Its lazy
        // read then returns current Effective Content by ID, just as paste
        // does; no second view-state check changes that choice.
        if change == "removed" {
            await history.emitObservedPage(fixturePage(rows: [], next: nil))
            await read.finish(.failure(.notFound(original.id)))
        } else if change == "hidden-type" {
            await history.emitObservedPage(fixturePage(rows: [Self.row(revised, types: ["public.url"])], next: nil))
            await read.finish(.success(PastePayload(
                item: revised,
                representations: [HistoryRepresentation(
                    typeIdentifier: "public.url", bytes: Data("https://example.invalid/".utf8)
                )],
                lineageHint: revised.id
            )))
        } else {
            await history.emitObservedPage(fixturePage(rows: [Self.row(revised)], next: nil))
            await read.finish(.success(Self.textPayload(revised, text: "current effective revision")))
        }
        let result = await loading.value
        if change == "revised" {
            #expect(result.bytes == Data("current effective revision".utf8))
            #expect(!result.failed)
        } else {
            #expect(result.bytes == nil)
            if change == "removed" { #expect(result.failed) }
        }
        #expect(state.failure == nil)
        await history.finishObservation()
    }

    @Test
    func hiddenOrStaleRowCannotAdvertiseDragContent() async throws {
        let reference = Self.reference(version: 1)
        let history = ScriptedHistory(observedFirstPage: fixturePage(rows: [Self.row(reference)], next: nil))
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 1 })
        state.typeFilter = .images
        #expect(state.dragItemProvider(for: reference).registeredTypeIdentifiers.isEmpty)
        state.typeFilter = .all
        #expect(state.dragItemProvider(for: Self.reference(version: 2)).registeredTypeIdentifiers.isEmpty)
        await history.finishObservation()
    }

    private static func load(
        _ provider: NSItemProvider,
        type: String = "public.utf8-plain-text"
    ) async -> DragLoadResult {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { bytes, error in
                continuation.resume(returning: DragLoadResult(bytes: bytes, failed: error != nil))
            }
        }
    }

    private static func reference(version: UInt64) -> HistoryItemReference {
        HistoryItemReference(
            id: HistoryItemID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000D401")!),
            contentVersion: ContentVersion(rawValue: version)
        )
    }

    private static func row(
        _ reference: HistoryItemReference,
        types: [String] = ["public.utf8-plain-text"]
    ) -> HistoryRow {
        HistoryRow(
            item: reference, title: "drag fixture", typeIdentifiers: types,
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 710_000_000),
            copyCount: 1, lastSource: nil, pinnedPosition: nil, search: nil
        )
    }

    private static func textPayload(_ reference: HistoryItemReference, text: String) -> PastePayload {
        PastePayload(
            item: reference,
            representations: [HistoryRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8))],
            lineageHint: reference.id
        )
    }
}

private struct DragLoadResult: Sendable {
    let bytes: Data?
    let failed: Bool
}

private actor PausedDragRead {
    private var continuation: CheckedContinuation<PastePayload, Error>?
    private var result: Result<PastePayload, HistoryFailure>?
    var isWaiting: Bool { continuation != nil }

    func value() async throws -> PastePayload {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<PastePayload, HistoryFailure>) {
        self.result = result
        let waiting = continuation
        continuation = nil
        switch result {
        case .success(let payload): waiting?.resume(returning: payload)
        case .failure(let failure): waiting?.resume(throwing: failure)
        }
    }
}
