import AppKit
import Foundation
@testable import HistoryCore
@testable import HistoryStorage
@testable import ClipyApp
import Testing

/// Real History capture/revision reads reach the same native pasteboard writers
/// passed to NSDraggingItem. The receiver observes independent ordered items.
@MainActor
struct DragItemProviderHistoryTests {
    @Test func multiItemDragPreservesFilesRepeatedTypesAndOpaqueBytes() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let original = try await capture(history, representations: [
            .init(typeIdentifier: "public.file-url", bytes: Data("file:///tmp/first.txt".utf8)),
            .init(typeIdentifier: "com.clipy.tests.opaque", bytes: Data([0, 255, 1])),
            .init(typeIdentifier: "public.file-url", bytes: Data("file:///tmp/second.txt".utf8), pasteboardItemIndex: 1),
            .init(typeIdentifier: "com.clipy.tests.opaque", bytes: Data([255, 0, 2]), pasteboardItemIndex: 1),
        ])
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.first?.item == original })
        let payload = try #require(try await state.dragPayload(for: original))
        let writers = try HistoryListDraggingView.pasteboardItems(for: payload)
        let board = NSPasteboard(name: .init("clipy.drag-test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(board.writeObjects(writers))
        let items = try #require(board.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].data(forType: .fileURL) == Data("file:///tmp/first.txt".utf8))
        #expect(items[1].data(forType: .fileURL) == Data("file:///tmp/second.txt".utf8))
        #expect(items[0].data(forType: .init("com.clipy.tests.opaque")) == Data([0, 255, 1]))
        #expect(items[1].data(forType: .init("com.clipy.tests.opaque")) == Data([255, 0, 2]))
        #expect(items.allSatisfy { $0.types.count == 2 })
    }

    @Test func oneItemOffersOnlyItsExactDynamicTypesWithoutGuessedUTF8() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let representations: [CapturedRepresentation] = [
            .init(typeIdentifier: "public.url", bytes: Data("https://example.invalid/".utf8)),
            .init(typeIdentifier: "public.utf16-plain-text", bytes: Data([0x41, 0])),
            .init(typeIdentifier: "dyn.clipy.opaque", bytes: Data([0, 255, 128])),
        ]
        let original = try await capture(history, representations: representations)
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.first?.item == original })
        let payload = try #require(try await state.dragPayload(for: original))
        let items = try HistoryListDraggingView.pasteboardItems(for: payload)
        #expect(items.count == 1)
        #expect(Set(items[0].types.map(\.rawValue)) == Set(representations.map(\.typeIdentifier)))
        #expect(!items[0].types.contains(.string))
        for representation in representations {
            #expect(items[0].data(forType: .init(representation.typeIdentifier)) == representation.bytes)
        }
    }

    @Test func oneFrozenDragKeepsAllFormatsAfterRevisionAndRemoval() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let original = try await capture(history, representations: [
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("first\0".utf8)),
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("second\0".utf8), pasteboardItemIndex: 1),
        ])
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.first?.item == original })
        let payload = try #require(try await state.dragPayload(for: original))
        let writers = try HistoryListDraggingView.pasteboardItems(for: payload)
        _ = try await history.perform(.revise(.init(
            itemID: original.id, expected: original.contentVersion,
            intent: .replace(.init(decisions: [
                .init(typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data("changed".utf8))),
                .init(typeIdentifier: "public.utf8-plain-text", action: .inheritCanonical, pasteboardItemIndex: 1),
            ]))
        )))
        _ = try await history.perform(.remove(original.id))
        #expect(writers[0].data(forType: .string) == Data("first\0".utf8))
        #expect(writers[1].data(forType: .string) == Data("second\0".utf8))
        #expect(state.failure == nil)
    }

    @Test func hiddenOrStaleRowsCannotBeginANativeDrag() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let original = try await capture(history, representations: [
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("visible".utf8)),
        ])
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.first?.item == original })
        let stale = HistoryItemReference(id: original.id, contentVersion: .init(rawValue: 2))
        #expect(try await state.dragPayload(for: stale) == nil)
        state.typeFilter = .images
        #expect(try await state.dragPayload(for: original) == nil)
        state.deactivate()
        #expect(try await state.dragPayload(for: original) == nil)
        #expect(state.failure == nil)
    }

    private func capture(_ history: SQLiteHistory, representations: [CapturedRepresentation]) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(.init(
            representations: representations,
            origin: .init(sourceApplication: nil, lineageHint: nil), observedAt: Date()
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}
