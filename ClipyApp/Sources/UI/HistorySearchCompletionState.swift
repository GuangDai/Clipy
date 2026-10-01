import Foundation
import HistoryCore
import Observation

enum HistorySearchCompletionCommand: Equatable {
    case previous, next, accept, dismiss, request
}

enum HistorySearchCompletionDecision {
    case unhandled
    case handled
    case insert(HistorySearchCompletionInsertion)
}

/// One search field owns its candidates, input position and pending insertion.
/// Candidate work never changes History selection or publishes clipboard rows.
@MainActor @Observable
final class HistorySearchCompletionState {
    private(set) var candidates: [HistorySearchCompletionCandidate] = []
    private(set) var selectedIndex = 0
    private(set) var isInputFocused = false
    private(set) var isComposing = false
    private(set) var insertion: HistorySearchCompletionInsertion?
    private(set) var availableHeight: Double = 240
    private(set) var isLoadingSources = false
    private(set) var sourceFailure = false

    var isPresented: Bool { !candidates.isEmpty || isLoadingSources || sourceFailure }
    var consumesPanelCommands: Bool { isPresented && isInputFocused && !isComposing }

    @ObservationIgnored private var input: HistorySearchCompletionInput?
    @ObservationIgnored private var context: HistorySearchCompletionContext?
    @ObservationIgnored private var suppressedText: String?
    @ObservationIgnored private var requestGeneration = 0
    @ObservationIgnored private var insertionGeneration = 0
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private var sourceWorker: HistorySearchSourceCompletionWorker?
    @ObservationIgnored private var applications: [SourceApplicationSearchResolver.Application]?
    @ObservationIgnored private var applicationProvider:
        (@MainActor @Sendable () async -> [SourceApplicationSearchResolver.Application])?
    @ObservationIgnored private var historyPosition: ChangePosition?
    @ObservationIgnored private var requestsOnFocus = false
    @ObservationIgnored private var episodeGeneration = 0
    @ObservationIgnored private var mode: SearchMode = .fuzzy

    func configure(
        history: any ClipboardHistory,
        mode: SearchMode = .fuzzy,
        applications: @escaping @MainActor @Sendable () async -> [SourceApplicationSearchResolver.Application]
    ) {
        let needsWorker = sourceWorker == nil
        let changedMode = self.mode != mode
        self.mode = mode
        if needsWorker { sourceWorker = HistorySearchSourceCompletionWorker(history: history) }
        applicationProvider = applications
        if isInputFocused, !isComposing, input != nil,
           changedMode || (needsWorker && context?.kind == .source) {
            refresh(explicit: context?.explicit ?? false)
        }
    }

    func setFocused(_ focused: Bool) {
        guard isInputFocused != focused else { return }
        isInputFocused = focused
        if !focused { dismiss() }
    }

    func setAvailableHeight(_ height: Double) {
        let bounded = height.isFinite ? max(0, min(240, height)) : 0
        if availableHeight != bounded { availableHeight = bounded }
    }

    func update(_ input: HistorySearchCompletionInput) {
        // Native selection/text notifications can repeat the same input.
        // Keep the current request (including explicit completion) and its
        // keyboard selection until the editor actually changes. Focus regain,
        // mode changes and newer History positions have their own refreshes.
        if self.input == input, context != nil, isInputFocused,
           !input.isComposing, !requestsOnFocus { return }
        let previousInput = self.input
        self.input = input
        isComposing = input.isComposing
        guard isInputFocused, !input.isComposing else { dismiss(); return }
        // Insertion or Escape stays closed until the next genuine text edit.
        if let suppressedText, input.text.utf8.elementsEqual(suppressedText.utf8) { return }
        suppressedText = nil
        let explicit = requestsOnFocus
        requestsOnFocus = false
        // A selection can grow inside the same term without changing its
        // prefix or replacement range. Keep its candidates and pending read;
        // insertion still uses the latest native input stored above.
        if !explicit, let context,
           previousInput.map({ $0.text.utf8.elementsEqual(input.text.utf8) }) == true,
           HistorySearchCompletionEngine.context(for: input, explicit: context.explicit, mode: mode) == context {
            return
        }
        refresh(explicit: explicit)
    }

    func requestFromMenu() {
        suppressedText = nil
        if isInputFocused, input != nil { refresh(explicit: true) }
        else { requestsOnFocus = true }
    }

    func updateHistoryPosition(_ position: ChangePosition?) {
        guard let position, historyPosition.map({ position > $0 }) ?? true else { return }
        historyPosition = position
        if context?.kind == .source, isInputFocused, !isComposing {
            refresh(explicit: context?.explicit ?? false, preservingSourceCandidates: true)
        }
    }

    func command(_ command: HistorySearchCompletionCommand) -> HistorySearchCompletionDecision {
        guard isInputFocused, !isComposing else { return .unhandled }
        switch command {
        case .request:
            suppressedText = nil
            refresh(explicit: true)
            return .handled
        case .dismiss:
            guard isPresented || isLoadingSources else { return .unhandled }
            suppressedText = input?.text
            dismiss()
            return .handled
        case .previous, .next:
            guard !candidates.isEmpty else { return isPresented ? .handled : .unhandled }
            selectedIndex = min(candidates.count - 1, max(0, selectedIndex + (command == .next ? 1 : -1)))
            return .handled
        case .accept:
            guard candidates.indices.contains(selectedIndex) else { return isPresented ? .handled : .unhandled }
            return accept(selectedIndex)
        }
    }

    @discardableResult
    func accept(id: String) -> HistorySearchCompletionDecision {
        guard let index = candidates.firstIndex(where: { $0.id.utf8.elementsEqual(id.utf8) }) else { return .unhandled }
        return accept(index)
    }

    @discardableResult
    func accept(_ index: Int) -> HistorySearchCompletionDecision {
        guard isInputFocused, !isComposing, let input,
              candidates.indices.contains(index) else { return .unhandled }
        let candidate = candidates[index]
        insertionGeneration += 1
        let edit = HistorySearchCompletionInsertion(
            id: insertionGeneration, originalText: input.text,
            replacementRange: candidate.replacementRange, text: candidate.insertion,
            selectionOffset: candidate.selectionOffset
        )
        insertion = edit
        // NSTextView performs the edit and publishes the bound query through
        // its ordinary delegate. The candidate owner does not rewrite it.
        let original = input.text as NSString
        if candidate.replacementRange.location <= original.length,
           candidate.replacementRange.length <= original.length - candidate.replacementRange.location {
            suppressedText = original.replacingCharacters(in: candidate.replacementRange, with: candidate.insertion)
        }
        dismiss()
        return .insert(edit)
    }

    func dismiss() {
        requestGeneration += 1
        sourceTask?.cancel()
        sourceTask = nil
        candidates = []
        selectedIndex = 0
        context = nil
        isLoadingSources = false
        sourceFailure = false
    }

    func close() {
        episodeGeneration += 1
        isInputFocused = false
        isComposing = false
        input = nil
        insertion = nil
        suppressedText = nil
        applications = nil
        historyPosition = nil
        requestsOnFocus = false
        dismiss()
        sourceWorker = nil
    }

    /// Search Options shares the same metadata vocabulary. Its structured
    /// task owns cancellation independently of native editor focus.
    func historySourceSuggestions(prefix: String, position: ChangePosition?) async throws -> [HistorySearchSourceCompletionWorker.Suggestion] {
        guard let sourceWorker else { throw HistoryFailure.temporarilyUnavailable(.factProof) }
        let episode = episodeGeneration
        let names: [SourceApplicationSearchResolver.Application]
        if let applications { names = applications }
        else {
            names = await applicationProvider?() ?? []
            try Task.checkCancellation()
            guard episode == episodeGeneration else { throw CancellationError() }
            applications = names
        }
        return try await sourceWorker.suggestions(prefix: prefix, position: position, applications: names)
    }

    private func refresh(explicit: Bool, preservingSourceCandidates: Bool = false) {
        guard isInputFocused, !isComposing, let input,
              let context = HistorySearchCompletionEngine.context(for: input, explicit: explicit, mode: mode) else {
            dismiss()
            return
        }
        let preservesCandidates = preservingSourceCandidates && context.kind == .source && self.context == context
        requestGeneration += 1
        let generation = requestGeneration
        sourceTask?.cancel()
        sourceTask = nil
        self.context = context
        if !preservesCandidates { selectedIndex = 0 }
        sourceFailure = false
        isLoadingSources = false
        if context.kind != .source {
            candidates = Array(HistorySearchCompletionEngine.candidates(for: context).prefix(8))
            return
        }
        if !preservesCandidates { candidates = [] }
        guard sourceWorker != nil else { return }
        isLoadingSources = true
        let position = historyPosition
        sourceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sources = try await self.historySourceSuggestions(prefix: context.prefix, position: position)
                guard !Task.isCancelled, self.requestGeneration == generation,
                      self.isInputFocused, !self.isComposing else { return }
                // Navigation remains available during a metadata refresh.
                // Preserve the user's choice at delivery, including any move
                // made while the read was waiting, by its exact identity.
                let selectedID = preservesCandidates && self.candidates.indices.contains(self.selectedIndex)
                    ? self.candidates[self.selectedIndex].id : nil
                let candidates = sources.map { source in
                    HistorySearchCompletionEngine.candidate(
                        id: "source." + Data(source.bundleID.utf8).base64EncodedString(),
                        title: source.displayName, subtitle: source.bundleID,
                        term: "source-id:" + HistorySearchExpression.quoted(source.bundleID), context: context
                    )
                }
                self.candidates = candidates
                self.selectedIndex = selectedID.flatMap { selectedID in
                    candidates.firstIndex { $0.id.utf8.elementsEqual(selectedID.utf8) }
                } ?? 0
                self.isLoadingSources = false
                self.sourceTask = nil
            } catch {
                guard !Task.isCancelled, self.requestGeneration == generation else { return }
                self.isLoadingSources = false
                self.sourceTask = nil
                self.sourceFailure = true
            }
        }
    }
}

/// Distinct source metadata is read in snapshot-bound pages. Matching and
/// ranking stay off MainActor; only eight display candidates return to it.
/// A small vocabulary is cached during this field episode. Larger catalogues
/// still scan every page without retaining a full-store corpus.
actor HistorySearchSourceCompletionWorker {
    struct Suggestion: Sendable, Identifiable {
        let bundleID: String
        let displayName: String
        let score: Int
        var id: Data { Data(bundleID.utf8) }
    }

    private let history: any ClipboardHistory
    private var cachedApplications: [String]?
    private var cachedPosition: ChangePosition?
    private var applicationNames: [Data: SourceApplicationSearchResolver.Application]?
    private static let maximumCachedCount = 2_048
    private static let maximumCachedBytes = 256 * 1_024

    init(history: any ClipboardHistory) { self.history = history }

    func suggestions(
        prefix: String, position: ChangePosition?,
        applications: [SourceApplicationSearchResolver.Application]
    ) async throws -> [Suggestion] {
        let names: [Data: SourceApplicationSearchResolver.Application]
        if let applicationNames { names = applicationNames }
        else {
            names = Dictionary(applications.map { (Data($0.bundleID.utf8), $0) }, uniquingKeysWith: { first, _ in first })
            applicationNames = names
        }
        // The UI's observed position is a lower bound: this metadata read
        // may already include a newer commit than its still-settling query.
        let canReusePosition = position.map { hint in cachedPosition.map { $0 >= hint } ?? false } ?? true
        if let cachedApplications, canReusePosition {
            return try rank(cachedApplications, prefix: prefix, names: names)
        }
        cachedApplications = nil
        cachedPosition = nil
        // One retry obtains a fresh coherent catalogue after a concurrent
        // commit expires its cursor; continuous mutations leave a retryable UI.
        for attempt in 0..<2 {
            do {
                var cursor: HistorySourceApplicationCursor?
                var snapshot: ChangePosition?
                var vocabulary: [String] = []
                var vocabularyBytes = 0
                var mayCache = true
                var ranked: [Suggestion] = []
                repeat {
                    try Task.checkCancellation()
                    let page = try await history.sourceApplications(.init(limit: 32, cursor: cursor))
                    try Task.checkCancellation()
                    if let snapshot, snapshot != page.position { throw HistoryFailure.snapshotExpired(current: page.position) }
                    snapshot = page.position
                    for identifier in page.applications {
                        appendSuggestion(identifier, prefix: prefix, names: names, into: &ranked)
                        if mayCache {
                            vocabularyBytes += identifier.utf8.count
                            if vocabulary.count < Self.maximumCachedCount, vocabularyBytes <= Self.maximumCachedBytes {
                                vocabulary.append(identifier)
                            } else {
                                mayCache = false
                                vocabulary = []
                            }
                        }
                    }
                    cursor = page.next
                } while cursor != nil
                try Task.checkCancellation()
                if mayCache {
                    cachedApplications = vocabulary
                    cachedPosition = snapshot
                }
                return ranked
            } catch let failure as HistoryFailure {
                guard attempt == 0, case .snapshotExpired = failure else { throw failure }
            }
        }
        throw HistoryFailure.temporarilyUnavailable(.factProof)
    }

    private func rank(
        _ identifiers: [String], prefix: String,
        names: [Data: SourceApplicationSearchResolver.Application]
    ) throws -> [Suggestion] {
        var ranked: [Suggestion] = []
        for (index, identifier) in identifiers.enumerated() {
            if index.isMultiple(of: 32) { try Task.checkCancellation() }
            appendSuggestion(identifier, prefix: prefix, names: names, into: &ranked)
        }
        return ranked
    }

    private func appendSuggestion(
        _ identifier: String, prefix: String,
        names: [Data: SourceApplicationSearchResolver.Application], into ranked: inout [Suggestion]
    ) {
        let application = names[Data(identifier.utf8)]
        var bestScore = HistorySearchCompletionEngine.matchScore(identifier, prefix: prefix)
        if let application, !prefix.isEmpty {
            for name in application.names {
                if let score = HistorySearchCompletionEngine.matchScore(name, prefix: prefix),
                   bestScore.map({ score < $0 }) ?? true {
                    bestScore = score
                }
            }
        }
        guard let score = bestScore else { return }
        ranked.append(Suggestion(bundleID: identifier, displayName: application?.displayName ?? identifier, score: score))
        ranked.sort {
            $0.score == $1.score ? $0.bundleID.utf8.lexicographicallyPrecedes($1.bundleID.utf8) : $0.score < $1.score
        }
        if ranked.count > 8 { ranked.removeLast() }
    }
}
