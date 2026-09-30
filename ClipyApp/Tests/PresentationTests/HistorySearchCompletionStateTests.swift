import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import ClipyApp

/// Suggestions come from the real retained occurrence catalogue. The wrapper
/// records or delays only reads; every mutation and returned page uses SQLite.
@MainActor
struct HistorySearchCompletionStateTests {
    enum Departure: CaseIterable, Equatable, Sendable { case focus, edit, close, composition }

    @Test func sourcesBeyondTheFirstTwoPagesAndEarlierCopiesShareOneBoundedVocabularyRead() async throws {
        let base = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        var position: ChangePosition?
        for index in 0..<70 {
            let commit = try await capture("same retained item", source: source(index), at: index, in: base)
            position = commit.position
        }
        let recent = try await base.browse(.init(kind: .recent, limit: 1))
        #expect(recent.rows.count == 1)
        #expect(recent.rows.first?.lastSource == source(69))
        let history = CompletionSourceReadHistory(base: base)
        let worker = HistorySearchSourceCompletionWorker(history: history)
        let names: [SourceApplicationSearchResolver.Application] = [
            .init(bundleID: source(0), displayName: "Retired Browser"),
            .init(bundleID: source(69), displayName: "Late Browser"),
            .init(bundleID: "com.example.never-copied", displayName: "Late Browser")
        ]
        let late = try await worker.suggestions(prefix: "late", position: position, applications: names)
        #expect(late.map(\.bundleID) == [source(69)])
        #expect(late.map(\.displayName) == ["Late Browser"])
        let requests = await history.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.limit == 32 })
        #expect(requests.first?.cursor == nil)
        #expect(requests.dropFirst().allSatisfy { $0.cursor != nil })

        let earlier = try await worker.suggestions(prefix: "retired", position: position, applications: names)
        let repeated = try await worker.suggestions(prefix: "retired", position: position, applications: names)
        #expect(earlier.map(\.bundleID) == [source(0)])
        #expect(repeated.map(\.bundleID) == earlier.map(\.bundleID))
        #expect(await history.requests.count == 3)
    }

    @Test func anAdvancedHistoryPositionWithdrawsRemovedSourcesAndCachesTheNewVocabulary() async throws {
        let base = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let alpha = try await capture("alpha item", source: "com.example.Alpha", at: 1, in: base)
        let beta = try await capture("beta item", source: "com.example.Beta", at: 2, in: base)
        guard case .inserted(let item) = alpha.outcome else { throw FixtureFailure.expectedInsertion }
        let history = CompletionSourceReadHistory(base: base)
        let state = completion(history: history, position: beta.position)
        defer { state.close() }
        state.update(input("$source:alp"))
        try #require(await pollUntil { !state.isLoadingSources && state.candidates.map(\.subtitle) == ["com.example.Alpha"] })
        #expect(await history.requests.count == 1)

        let receipt = try await base.perform(.remove(item.id))
        guard case .committed(let removal) = receipt else { throw FixtureFailure.expectedCommit }
        state.updateHistoryPosition(removal.position)
        #expect(state.isLoadingSources)
        try #require(await pollUntil { !state.isLoadingSources })
        #expect(state.candidates.isEmpty)
        #expect(!state.isPresented)
        #expect(await history.requests.count == 2)

        state.update(input("$source:bet"))
        try #require(await pollUntil { !state.isLoadingSources && state.candidates.map(\.subtitle) == ["com.example.Beta"] })
        #expect(await history.requests.count == 2)
    }

    @Test(arguments: Departure.allCases)
    func lateSourceDeliveryCannotPublishAfterItsInputOwnerDeparts(_ departure: Departure) async throws {
        let base = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let commit = try await capture("alpha item", source: "com.example.Alpha", at: 1, in: base)
        let history = CompletionSourceReadHistory(base: base)
        await history.holdNextRead()
        let state = completion(history: history, position: commit.position)
        defer {
            state.close()
            Task { await history.releaseRead() }
        }
        state.update(input("$source:alp"))
        try #require(await pollUntil { await history.isHoldingRead })
        switch departure {
        case .focus: state.setFocused(false)
        case .edit: state.update(input("$type:li"))
        case .close: state.close()
        case .composition: state.update(input("$source:alp", composing: true))
        }
        let expected = state.candidates
        await history.releaseRead()
        try #require(await pollUntil { await history.completedReads == 1 })
        // The delayed read deliberately ignores cancellation until it returns
        // real data. Cancellation belongs to the departed UI request itself.
        #expect(await history.cancelledDeliveries == 1)
        await Task.yield()
        #expect(state.candidates == expected)
        #expect(!state.candidates.contains { $0.subtitle == "com.example.Alpha" })
        #expect(!state.isLoadingSources)
        #expect(!state.sourceFailure)
        if departure == .edit { #expect(state.candidates.map(\.insertion) == ["type:links$"]) }
        else { #expect(!state.isPresented) }
    }

    @Test func pendingAndFailedSourcePopupsConsumeCommandsWhileEmptyFocusAndIMEKeepThemUnhandled() async throws {
        let base = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let commit = try await capture("alpha item", source: "com.example.Alpha", at: 1, in: base)
        let history = CompletionSourceReadHistory(base: base)
        let state = completion(history: history, position: commit.position)
        defer {
            state.close()
            Task { await history.releaseRead() }
        }
        state.update(input(""))
        for command in [HistorySearchCompletionCommand.previous, .next, .accept, .dismiss] {
            let decision = state.command(command)
            #expect(isUnhandled(decision))
        }
        await history.holdNextRead()
        state.update(input("$source:alp"))
        try #require(await pollUntil { await history.isHoldingRead })
        #expect(state.candidates.isEmpty)
        #expect(state.consumesPanelCommands)
        for command in [HistorySearchCompletionCommand.previous, .next, .accept] {
            let decision = state.command(command)
            #expect(isHandled(decision))
        }
        let dismissal = state.command(.dismiss)
        #expect(isHandled(dismissal))
        await history.releaseRead()
        try #require(await pollUntil { await history.completedReads == 1 })

        await history.rejectNextRead()
        state.update(input("$source:alph"))
        try #require(await pollUntil { state.sourceFailure && !state.isLoadingSources })
        #expect(state.candidates.isEmpty)
        #expect(state.consumesPanelCommands)
        for command in [HistorySearchCompletionCommand.previous, .next, .accept] {
            let decision = state.command(command)
            #expect(isHandled(decision))
        }

        state.update(input("$type:li", composing: true))
        #expect(!state.isPresented)
        #expect(!state.consumesPanelCommands)
        for command in [HistorySearchCompletionCommand.previous, .next, .accept, .dismiss, .request] {
            let decision = state.command(command)
            #expect(isUnhandled(decision))
        }
        #expect(state.insertion == nil)
    }

    private func completion(history: any ClipboardHistory, position: ChangePosition) -> HistorySearchCompletionState {
        let state = HistorySearchCompletionState()
        state.configure(history: history, applications: { [] })
        state.updateHistoryPosition(position)
        state.setFocused(true)
        return state
    }

    private func input(_ text: String, composing: Bool = false) -> HistorySearchCompletionInput {
        .init(text: text, selection: NSRange(location: text.utf16.count, length: 0), isComposing: composing)
    }

    private func source(_ index: Int) -> String { String(format: "com.example.source.%03d", index) }

    private func capture(_ text: String, source: String, at time: Int, in history: SQLiteHistory) async throws -> HistoryCommit {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8))],
            origin: .init(sourceApplication: source, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_900_000 + Double(time))
        )))
        guard case .committed(let commit) = receipt else { throw FixtureFailure.expectedCommit }
        return commit
    }

    private func isHandled(_ decision: HistorySearchCompletionDecision) -> Bool {
        if case .handled = decision { return true }
        return false
    }

    private func isUnhandled(_ decision: HistorySearchCompletionDecision) -> Bool {
        if case .unhandled = decision { return true }
        return false
    }

    private enum FixtureFailure: Error { case expectedCommit, expectedInsertion }
}

private actor CompletionSourceReadHistory: ClipboardHistory {
    let base: SQLiteHistory
    private(set) var requests: [HistorySourceApplicationRequest] = []
    private(set) var completedReads = 0
    private(set) var cancelledDeliveries = 0
    private var shouldHold = false
    private var shouldReject = false
    private var release: CheckedContinuation<Void, Never>?
    var isHoldingRead: Bool { release != nil }

    init(base: SQLiteHistory) { self.base = base }

    func holdNextRead() { shouldHold = true }
    func rejectNextRead() { shouldReject = true }
    func releaseRead() {
        release?.resume()
        release = nil
    }

    func sourceApplications(_ request: HistorySourceApplicationRequest) async throws -> HistorySourceApplicationPage {
        requests.append(request)
        let held = shouldHold
        let rejected = shouldReject
        shouldHold = false
        shouldReject = false
        defer { completedReads += 1 }
        // Exercise a real facade rejection, with no fabricated page or error.
        let forwarded = rejected ? HistorySourceApplicationRequest(limit: 0, cursor: request.cursor) : request
        let page = try await base.sourceApplications(forwarded)
        if held { await withCheckedContinuation { release = $0 } }
        if Task.isCancelled { cancelledDeliveries += 1 }
        return page
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt { try await base.perform(action) }
    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage { try await base.browse(request) }
    func observe(_ request: HistoryObservationRequest) async -> AsyncThrowingStream<HistoryPage, Error> { await base.observe(request) }
    func details(for id: HistoryItemID) async throws -> HistoryDetails { try await base.details(for: id) }
    func representationMetadata(for item: HistoryItemReference) async throws -> [HistoryRepresentationMetadata] {
        try await base.representationMetadata(for: item)
    }
    func copySources(for id: HistoryItemID, expectedCopyCount: UInt64, offset: Int) async throws -> HistoryCopySourcePage {
        try await base.copySources(for: id, expectedCopyCount: expectedCopyCount, offset: offset)
    }
    func representation(_ request: HistoryRepresentationRequest) async throws -> HistoryRepresentation {
        try await base.representation(request)
    }
    func pastePayload(for id: HistoryItemID) async throws -> PastePayload { try await base.pastePayload(for: id) }
    func thumbnail(for item: HistoryItemReference, pixels: PixelSize) async throws -> ThumbnailPayload? {
        try await base.thumbnail(for: item, pixels: pixels)
    }
    func usage() async throws -> HistoryUsage { try await base.usage() }
    func backup(to directory: URL) async throws -> HistoryBackupReceipt { try await base.backup(to: directory) }
    func retentionConfiguration() async throws -> HistoryRetentionConfiguration { try await base.retentionConfiguration() }
}
