import Foundation
import Observation

enum BuiltInAutomationFilter: String, CaseIterable {
    case all, manual, automatic, unsaved

    var title: String {
        switch self {
        case .all: "All workflows"
        case .manual: "Manual workflows"
        case .automatic: "Automatic workflows"
        case .unsaved: "Unsaved workflows"
        }
    }
}

/// One window owns drafts and temporary input. Only explicit saves update the
/// definitions consumed by automatic execution (V2-13); filtering never changes
/// execution order, selection, or another draft's text.
@MainActor @Observable
final class BuiltInAutomationWorkspace {
    let library: BuiltInAutomationLibrary
    var workflow: BuiltInAutomationWorkflow {
        didSet { retainDraft() }
    }
    var source: String
    var query = ""
    var filter: BuiltInAutomationFilter = .all
    private(set) var drafts: [BuiltInAutomationWorkflow]
    private var inputs: [UUID: String] = [:]
    private let editorInput: Bool
    private var placeholder: BuiltInAutomationWorkflow?
    private var savedBaseline: [UUID: BuiltInAutomationWorkflow]

    init(source: String = "", editorInput: Bool = false, defaults: UserDefaults = .standard) {
        let library = BuiltInAutomationLibrary(defaults: defaults)
        self.library = library
        self.source = source
        self.editorInput = editorInput
        let loaded = library.workflows
        drafts = loaded
        savedBaseline = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        if !editorInput, let first = loaded.first {
            workflow = first
        } else {
            let blank = Self.blank()
            workflow = blank
            drafts.append(blank)
            placeholder = blank
        }
    }

    var visibleDrafts: [BuiltInAutomationWorkflow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return drafts.filter { draft in
            let includes: Bool
            switch filter {
            case .all: includes = true
            case .manual: includes = draft.trigger.includesManual
            case .automatic: includes = draft.trigger.includesAutomatic
            case .unsaved: includes = isDirty(draft)
            }
            return includes && (term.isEmpty || draft.name.localizedStandardContains(term))
        }
    }

    var changedDrafts: [BuiltInAutomationWorkflow] {
        drafts.filter { isDirty($0) && $0 != placeholder }
    }
    var hasUnsavedChanges: Bool { !changedDrafts.isEmpty }
    var canReorder: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filter == .all }

    func isDirty(_ draft: BuiltInAutomationWorkflow) -> Bool {
        savedBaseline[draft.id] != draft
    }

    func select(_ id: UUID) {
        guard id != workflow.id, let next = drafts.first(where: { $0.id == id }) else { return }
        inputs[workflow.id] = source
        workflow = next
        if !editorInput { source = inputs[id] ?? "" }
    }

    func add(_ value: BuiltInAutomationWorkflow) {
        query = ""
        filter = .all
        drafts.append(value)
        select(value.id)
    }

    func saveSelection() throws {
        let refresh = Set(drafts.filter { !isDirty($0) }.map(\.id)).union([workflow.id])
        // Existing rows already persist explicit moves. Editing their content
        // must not undo an unrelated reorder from another open window.
        let order = savedBaseline[workflow.id] == nil ? drafts.map(\.id) : []
        try library.save(workflow, orderedIDs: order)
        refreshSavedDrafts(refresh)
    }

    func saveAll() throws {
        let changed = changedDrafts
        let savedIDs = Set(changed.map(\.id)).union(drafts.filter { !isDirty($0) }.map(\.id))
        let order = changed.contains { savedBaseline[$0.id] == nil } ? drafts.map(\.id) : []
        try library.saveAll(changed, orderedIDs: order)
        // Refresh saved and untouched drafts. A different window's unrelated
        // update must not replace this window's unsaved text or selection.
        refreshSavedDrafts(savedIDs)
    }

    func discardSelection() throws {
        let refresh = Set(drafts.filter { !isDirty($0) }.map(\.id)).union([workflow.id])
        // Read before touching drafts: a corrupt external edit must never
        // turn Revert into silent removal of the user's local work.
        try library.refresh()
        refreshSavedDrafts(refresh)
    }

    func remove(_ id: UUID) throws {
        if library.workflows.contains(where: { $0.id == id }) { try library.remove(id) }
        removeDraft(id)
    }

    func move(_ id: UUID, before target: UUID?) throws {
        guard canReorder, id != target, let index = drafts.firstIndex(where: { $0.id == id }),
              target == nil || drafts.contains(where: { $0.id == target }) else { return }
        var reordered = drafts
        let moved = reordered.remove(at: index)
        let destination = target.flatMap { target in reordered.firstIndex { $0.id == target } } ?? reordered.endIndex
        reordered.insert(moved, at: destination)
        if library.workflows.contains(where: { $0.id == id }) {
            let following = reordered.drop(while: { $0.id != id }).dropFirst()
                .first { draft in library.workflows.contains { $0.id == draft.id } }
            try library.move(id: id, before: following?.id)
        }
        drafts = reordered
    }

    private func retainDraft() {
        if let index = drafts.firstIndex(where: { $0.id == workflow.id }) { drafts[index] = workflow }
    }

    private func refreshSavedDrafts(_ ids: Set<UUID>) {
        let selectedID = workflow.id
        let localDrafts = drafts.enumerated().filter { !ids.contains($0.element.id) }
        let localIDs = Set(localDrafts.map(\.element.id))
        // Saved definitions follow the actual execution order, including new
        // rows from other windows. Local unsaved/edited rows keep their slots.
        var refreshed = library.workflows.filter { !localIDs.contains($0.id) }
        savedBaseline = savedBaseline.filter { localIDs.contains($0.key) }
        for saved in refreshed { savedBaseline[saved.id] = saved }
        for (index, draft) in localDrafts {
            refreshed.insert(draft, at: min(index, refreshed.count))
        }
        drafts = refreshed
        let retainedIDs = Set(drafts.map(\.id))
        inputs = inputs.filter { retainedIDs.contains($0.key) }
        if let selected = drafts.first(where: { $0.id == selectedID }) {
            workflow = selected
        } else if let first = drafts.first {
            workflow = first
            if !editorInput { source = inputs[first.id] ?? "" }
        } else {
            let blank = Self.blank()
            placeholder = blank
            drafts = [blank]
            workflow = blank
            if !editorInput { source = "" }
        }
    }

    private func removeDraft(_ id: UUID) {
        drafts.removeAll { $0.id == id }
        inputs.removeValue(forKey: id)
        savedBaseline.removeValue(forKey: id)
        guard workflow.id == id else { return }
        if let next = drafts.first {
            workflow = next
            if !editorInput { source = inputs[next.id] ?? "" }
        } else {
            let blank = Self.blank()
            placeholder = blank
            drafts.append(blank)
            workflow = blank
            if !editorInput { source = "" }
        }
    }

    private static func blank() -> BuiltInAutomationWorkflow {
        .init(name: "", steps: [.init(operation: .trim)])
    }
}
