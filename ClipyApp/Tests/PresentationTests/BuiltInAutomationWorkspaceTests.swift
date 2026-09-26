import Foundation
@testable import ClipyApp
import Testing

@MainActor
struct BuiltInAutomationWorkspaceTests {
    @Test func switchingRetainsEachDraftAndItsTemporaryInput() throws {
        let suite = "WorkflowWorkspaceSwitching.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = workflow("First")
        let second = workflow("Second")
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([first, second])
        let workspace = BuiltInAutomationWorkspace(source: "First input", defaults: defaults)
        workspace.workflow.name = "First edited"
        workspace.workflow.steps.append(.init(operation: .uppercase))
        let editedFirst = workspace.workflow
        workspace.select(second.id)
        #expect(workspace.source.isEmpty)
        workspace.source = "Second input"
        workspace.workflow.name = "Second edited"
        let editedSecond = workspace.workflow

        workspace.select(first.id)
        #expect(workspace.workflow == editedFirst)
        #expect(workspace.source == "First input")
        workspace.select(second.id)
        #expect(workspace.workflow == editedSecond)
        #expect(workspace.source == "Second input")
        #expect(workspace.changedDrafts == [editedFirst, editedSecond])
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [first, second])
    }

    @Test func editorInputStaysSharedWhenSelectingWorkflows() throws {
        let suite = "WorkflowWorkspaceEditorInput.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = workflow("Saved")
        try BuiltInAutomationLibrary(defaults: defaults).save(saved)
        let workspace = BuiltInAutomationWorkspace(source: "Editor draft", editorInput: true, defaults: defaults)
        let placeholderID = workspace.workflow.id
        #expect(placeholderID != saved.id)
        workspace.select(saved.id)
        #expect(workspace.source == "Editor draft")
        workspace.source = "Edited temporary input"
        workspace.select(placeholderID)
        #expect(workspace.source == "Edited temporary input")
        #expect(!workspace.hasUnsavedChanges)
    }

    @Test func filtersAndSearchKeepSelectionInputAndExecutionOrder() throws {
        let suite = "WorkflowWorkspaceFiltering.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manual = workflow("Text cleanup")
        let automatic = workflow("Automatic cleanup", trigger: .newCopies)
        let both = workflow("Shared JSON", trigger: .both)
        let originals = [manual, automatic, both]
        try BuiltInAutomationLibrary(defaults: defaults).saveAll(originals)
        let workspace = BuiltInAutomationWorkspace(source: "Selected input", defaults: defaults)

        workspace.filter = .automatic
        #expect(workspace.visibleDrafts == [automatic, both])
        workspace.query = " json "
        #expect(workspace.visibleDrafts == [both])
        #expect(!workspace.canReorder)
        try workspace.move(both.id, before: manual.id)
        #expect(workspace.drafts == originals)
        #expect(workspace.workflow == manual)
        #expect(workspace.source == "Selected input")
        workspace.query = ""
        workspace.filter = .manual
        #expect(workspace.visibleDrafts == [manual, both])
        workspace.workflow.name = "Unsaved cleanup"
        workspace.filter = .unsaved
        #expect(workspace.visibleDrafts.map(\.id) == [manual.id])
        workspace.filter = .all
        #expect(workspace.canReorder)
        #expect(workspace.drafts.map(\.id) == originals.map(\.id))
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == originals)
    }

    @Test func saveAllIgnoresAnUntouchedPlaceholderAndSavesChangedDraftsInOrder() throws {
        let suite = "WorkflowWorkspaceSaveAll.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = workflow("Existing")
        try BuiltInAutomationLibrary(defaults: defaults).save(existing)
        let workspace = BuiltInAutomationWorkspace(editorInput: true, defaults: defaults)
        let placeholder = workspace.workflow
        #expect(!workspace.hasUnsavedChanges)
        let added = workflow(" New workflow ")
        workspace.add(added)
        try workspace.move(added.id, before: existing.id)
        workspace.select(existing.id)
        workspace.workflow.steps.append(.init(operation: .uppercase))
        let edited = workspace.workflow
        try workspace.saveAll()

        let saved = BuiltInAutomationLibrary(defaults: defaults).workflows
        #expect(saved.map(\.id) == [added.id, existing.id])
        #expect(saved.map(\.name) == ["New workflow", "Existing"])
        #expect(saved.last == edited)
        #expect(!saved.contains { $0.id == placeholder.id })
        #expect(workspace.drafts.contains(placeholder))
        #expect(workspace.changedDrafts.isEmpty)
        #expect(!workspace.hasUnsavedChanges)
    }

    @Test func invalidDraftMakesSaveAllLeaveAllSavedDefinitionsUnchanged() throws {
        let suite = "WorkflowWorkspaceInvalidSave.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = workflow("Original")
        try BuiltInAutomationLibrary(defaults: defaults).save(original)
        let workspace = BuiltInAutomationWorkspace(defaults: defaults)
        workspace.workflow.name = "Edited original"
        let edited = workspace.workflow
        let invalid = BuiltInAutomationWorkflow(name: "Incomplete", steps: [.init(operation: .replace)])
        workspace.add(invalid)
        let before = try #require(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey))

        #expect(throws: BuiltInAutomationFailure.emptyFind) { try workspace.saveAll() }
        #expect(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey) == before)
        #expect(workspace.library.workflows == [original])
        #expect(workspace.changedDrafts == [edited, invalid])
        #expect(workspace.workflow == invalid)
        try workspace.discardSelection()
        #expect(workspace.workflow == edited)
        #expect(workspace.changedDrafts == [edited])
    }

    @Test func duplicateIsAnUnsavedManualDraftUntilExplicitSave() throws {
        let suite = "WorkflowWorkspaceDuplicate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = workflow("Automatic", trigger: .newCopies)
        try BuiltInAutomationLibrary(defaults: defaults).save(original)
        let workspace = BuiltInAutomationWorkspace(defaults: defaults)
        workspace.query = "Automatic"
        workspace.filter = .automatic
        let duplicate = workspace.workflow.duplicated(named: "Manual copy")
        workspace.add(duplicate)

        #expect(workspace.workflow.id == duplicate.id)
        #expect(workspace.workflow.trigger == .manual)
        #expect(workspace.changedDrafts == [duplicate])
        #expect(workspace.query.isEmpty && workspace.filter == .all)
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [original])
        try workspace.saveSelection()
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [original, duplicate])
        #expect(!workspace.hasUnsavedChanges)
    }

    @Test func savingSelectionRefreshesOtherWindowsUneditedDraftWithoutMarkingItDirty() throws {
        let suite = "WorkflowWorkspaceOtherWindow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = workflow("Alpha")
        var beta = workflow("Beta")
        let gamma = workflow("Gamma")
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([alpha, beta, gamma])
        let workspace = BuiltInAutomationWorkspace(source: "Alpha input", defaults: defaults)
        workspace.select(gamma.id)
        workspace.workflow.name = "Gamma unsaved"
        workspace.source = "Gamma input"
        let editedGamma = workspace.workflow
        workspace.select(alpha.id)
        workspace.workflow.name = "Alpha edited"
        let editedAlpha = workspace.workflow

        beta.name = "Beta edited elsewhere"
        let otherWindow = BuiltInAutomationLibrary(defaults: defaults)
        try otherWindow.save(beta)
        try workspace.saveSelection()
        #expect(workspace.drafts == [editedAlpha, beta, editedGamma])
        #expect(workspace.changedDrafts == [editedGamma])
        #expect(!workspace.isDirty(beta))
        #expect(workspace.workflow == editedAlpha)
        #expect(workspace.source == "Alpha input")

        try workspace.saveAll()
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [editedAlpha, beta, editedGamma])
        #expect(!workspace.hasUnsavedChanges)
        workspace.select(gamma.id)
        #expect(workspace.source == "Gamma input")
    }

    @Test func saveAllPreservesOtherWindowsAdditionsAndRefreshesItsEdits() throws {
        let suite = "WorkflowWorkspaceMergedBatch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = workflow("Alpha")
        var beta = workflow("Beta")
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([alpha, beta])
        let workspace = BuiltInAutomationWorkspace(defaults: defaults)
        workspace.workflow.name = "Alpha edited"
        let editedAlpha = workspace.workflow
        let localAdded = workflow("Local addition")
        workspace.add(localAdded)
        let elsewhereAdded = workflow("Other window addition")
        beta.name = "Beta edited elsewhere"
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([beta, elsewhereAdded])

        try workspace.saveAll()
        #expect(workspace.changedDrafts.isEmpty)
        #expect(workspace.drafts == [editedAlpha, beta, elsewhereAdded, localAdded])
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows
                == [editedAlpha, beta, elsewhereAdded, localAdded])
        workspace.workflow.name = "Local changed again"
        let editedLocal = workspace.workflow
        try workspace.saveAll()
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows
                == [editedAlpha, beta, elsewhereAdded, editedLocal])
    }

    @Test func discardingRestoresSavedDefinitionWithoutDiscardingTemporaryInput() throws {
        let suite = "WorkflowWorkspaceDiscard.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = workflow("Original")
        try BuiltInAutomationLibrary(defaults: defaults).save(original)
        let workspace = BuiltInAutomationWorkspace(source: "Temporary input", defaults: defaults)
        workspace.workflow.name = "Unsaved rename"
        workspace.workflow.trigger = .both
        try workspace.discardSelection()
        #expect(workspace.workflow == original)
        #expect(workspace.source == "Temporary input")
        #expect(!workspace.hasUnsavedChanges)
        try workspace.remove(original.id)
        #expect(workspace.library.workflows.isEmpty)
        #expect(workspace.drafts.count == 1)
        #expect(workspace.workflow.name.isEmpty)
        #expect(!workspace.hasUnsavedChanges)
    }

    @Test func contentSavesDoNotUndoOtherWindowsExecutionOrder() throws {
        let suite = "WorkflowWorkspaceConcurrentOrder.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = workflow("Alpha")
        let beta = workflow("Beta")
        let gamma = workflow("Gamma")
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([alpha, beta, gamma])
        let workspace = BuiltInAutomationWorkspace(defaults: defaults)
        let otherWindow = BuiltInAutomationLibrary(defaults: defaults)
        try otherWindow.move(id: gamma.id, before: alpha.id)

        workspace.workflow.name = "Alpha edited"
        let editedAlpha = workspace.workflow
        try workspace.saveSelection()
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [gamma, editedAlpha, beta])
        #expect(workspace.drafts == [gamma, editedAlpha, beta])
        workspace.select(beta.id)
        workspace.workflow.name = "Beta edited"
        let editedBeta = workspace.workflow
        try workspace.saveAll()
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [gamma, editedAlpha, editedBeta])
        #expect(workspace.drafts == [gamma, editedAlpha, editedBeta])
        try workspace.saveAll()
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [gamma, editedAlpha, editedBeta])
    }

    @Test func savingRefreshesSavedPriorityAndExternalAdditionsAroundLocalDrafts() throws {
        let suite = "WorkflowWorkspaceVisiblePriority.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = workflow("Alpha")
        let beta = workflow("Beta")
        let gamma = workflow("Gamma")
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([alpha, beta, gamma])
        let workspace = BuiltInAutomationWorkspace(source: "Alpha input", defaults: defaults)
        let local = workflow("Local draft")
        workspace.add(local)
        workspace.source = "Local input"
        try workspace.move(local.id, before: beta.id)
        workspace.select(beta.id)
        workspace.workflow.name = "Beta unsaved"
        workspace.source = "Beta input"
        let editedBeta = workspace.workflow
        workspace.select(alpha.id)
        workspace.workflow.name = "Alpha saved"
        let editedAlpha = workspace.workflow
        let external = workflow("External addition")
        let otherWindow = BuiltInAutomationLibrary(defaults: defaults)
        try otherWindow.move(id: gamma.id, before: alpha.id)
        try otherWindow.save(external)

        try workspace.saveSelection()

        #expect(workspace.drafts == [gamma, local, editedAlpha, editedBeta, external])
        #expect(workspace.changedDrafts == [local, editedBeta])
        #expect(workspace.workflow == editedAlpha)
        #expect(workspace.source == "Alpha input")
        #expect(!workspace.isDirty(external))
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [gamma, editedAlpha, beta, external])
        workspace.select(local.id)
        #expect(workspace.source == "Local input")
        workspace.select(beta.id)
        #expect(workspace.source == "Beta input")
    }

    @Test func savedDirtyWorkflowUsesLatestExecutionPositionWithoutLosingItsLocalEdit() throws {
        let suite = "WorkflowWorkspaceDirtyPriority.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = workflow("Alpha", trigger: .newCopies)
        let beta = workflow("Beta", trigger: .newCopies)
        let gamma = workflow("Gamma", trigger: .newCopies)
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([alpha, beta, gamma])
        let workspace = BuiltInAutomationWorkspace(source: "Alpha input", defaults: defaults)
        workspace.workflow.name = "Alpha local edit"
        let editedAlpha = workspace.workflow
        workspace.select(beta.id)
        workspace.workflow.name = "Beta saved edit"
        let editedBeta = workspace.workflow
        let otherWindow = BuiltInAutomationLibrary(defaults: defaults)
        try otherWindow.move(id: gamma.id, before: alpha.id)
        try otherWindow.move(id: beta.id, before: alpha.id)

        try workspace.saveSelection()

        #expect(workspace.drafts == [gamma, editedBeta, editedAlpha])
        #expect(workspace.drafts.map(\.id) == workspace.library.workflows.map(\.id))
        #expect(workspace.changedDrafts == [editedAlpha])
        #expect(workspace.workflow == editedBeta)
        workspace.select(alpha.id)
        #expect(workspace.source == "Alpha input")
        workspace.workflow = alpha
        #expect(!workspace.isDirty(alpha), "The original saved baseline survives moving the local edit")
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [gamma, editedBeta, alpha])
    }

    @Test func externalDeletionRetainsOnlyLocallyEditedDraftsAndKeepsThemUnsaved() throws {
        let suite = "WorkflowWorkspaceDeletedLocalDraft.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = workflow("Alpha")
        let beta = workflow("Beta")
        let gamma = workflow("Gamma")
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([alpha, beta, gamma])
        let workspace = BuiltInAutomationWorkspace(source: "Alpha input", defaults: defaults)
        workspace.workflow.name = "Alpha local edit"
        let editedAlpha = workspace.workflow
        workspace.select(beta.id)
        workspace.workflow.name = "Beta saved edit"
        let editedBeta = workspace.workflow
        let otherWindow = BuiltInAutomationLibrary(defaults: defaults)
        try otherWindow.remove(alpha.id)
        try otherWindow.remove(gamma.id)

        try workspace.saveSelection()

        #expect(workspace.drafts == [editedAlpha, editedBeta])
        #expect(workspace.library.workflows == [editedBeta])
        #expect(workspace.changedDrafts == [editedAlpha])
        workspace.select(alpha.id)
        #expect(workspace.source == "Alpha input")
        workspace.workflow = alpha
        #expect(workspace.isDirty(alpha), "An externally deleted draft stays unsaved even when its text is restored")
    }

    @Test func explicitMoveCombinesLatestSavedOrderWithLocalEditsAndInputs() throws {
        let suite = "WorkflowWorkspaceMoveRefresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = workflow("Alpha")
        let beta = workflow("Beta")
        let gamma = workflow("Gamma")
        let delta = workflow("Delta")
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([alpha, beta, gamma, delta])
        let workspace = BuiltInAutomationWorkspace(source: "Alpha input", defaults: defaults)
        workspace.workflow.name = "Alpha unsaved"
        let editedAlpha = workspace.workflow
        let local = workflow("Local draft")
        workspace.add(local)
        workspace.source = "Local input"
        workspace.select(alpha.id)
        try BuiltInAutomationLibrary(defaults: defaults).move(id: delta.id, before: alpha.id)

        try workspace.move(gamma.id, before: alpha.id)

        #expect(workspace.drafts == [delta, gamma, editedAlpha, beta, local])
        #expect(workspace.library.workflows == [delta, gamma, alpha, beta])
        #expect(workspace.changedDrafts == [editedAlpha, local])
        #expect(workspace.workflow == editedAlpha)
        #expect(workspace.source == "Alpha input")
        workspace.select(local.id)
        #expect(workspace.source == "Local input")
    }

    @Test func removalRefreshesLatestPriorityAndSelectsExistingSavedSuccessor() throws {
        let suite = "WorkflowWorkspaceRemoveRefresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = workflow("Alpha")
        let beta = workflow("Beta")
        let gamma = workflow("Gamma")
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([alpha, beta, gamma])
        let workspace = BuiltInAutomationWorkspace(source: "Alpha input", defaults: defaults)
        workspace.workflow.name = "Alpha unsaved"
        let editedAlpha = workspace.workflow
        workspace.select(beta.id)
        let external = workflow("External")
        let otherWindow = BuiltInAutomationLibrary(defaults: defaults)
        try otherWindow.move(id: gamma.id, before: alpha.id)
        try otherWindow.save(external)

        try workspace.remove(beta.id)

        #expect(workspace.drafts == [gamma, editedAlpha, external])
        #expect(workspace.library.workflows == [gamma, alpha, external])
        #expect(workspace.workflow == gamma)
        #expect(workspace.changedDrafts == [editedAlpha])
        workspace.select(alpha.id)
        #expect(workspace.source == "Alpha input")
        try workspace.remove(alpha.id)
        try workspace.remove(gamma.id)
        #expect(workspace.workflow == external)
        #expect(workspace.drafts == [external])
    }

    @Test(arguments: [false, true])
    func unreadableSavedDefinitionsPreventMoveOrRemovalWithoutLosingDrafts(remove: Bool) throws {
        let suite = "WorkflowWorkspaceMutationReadFailure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = workflow("Alpha")
        let beta = workflow("Beta")
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([alpha, beta])
        let workspace = BuiltInAutomationWorkspace(source: "Alpha input", defaults: defaults)
        workspace.workflow.name = "Alpha unsaved"
        let editedAlpha = workspace.workflow
        defaults.set(Data("unreadable".utf8), forKey: BuiltInAutomationLibrary.defaultsKey)

        #expect(throws: BuiltInAutomationFailure.unreadableWorkflows) {
            if remove { try workspace.remove(alpha.id) }
            else { try workspace.move(alpha.id, before: nil) }
        }

        #expect(workspace.drafts == [editedAlpha, beta])
        #expect(workspace.workflow == editedAlpha)
        #expect(workspace.source == "Alpha input")
        #expect(workspace.changedDrafts == [editedAlpha])
    }

    @Test func discardingUsesOtherWindowsLatestSavedDefinition() throws {
        let suite = "WorkflowWorkspaceLatestDiscard.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = workflow("Original")
        try BuiltInAutomationLibrary(defaults: defaults).save(original)
        let workspace = BuiltInAutomationWorkspace(source: "Temporary input", defaults: defaults)
        workspace.workflow.name = "Local unsaved"
        var latest = original
        latest.name = "Saved elsewhere"
        latest.steps.append(.init(operation: .uppercase))
        try BuiltInAutomationLibrary(defaults: defaults).save(latest)

        try workspace.discardSelection()

        #expect(workspace.workflow == latest)
        #expect(workspace.drafts == [latest])
        #expect(workspace.source == "Temporary input")
        #expect(!workspace.hasUnsavedChanges)
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [latest])
    }

    @Test func discardingExternallyDeletedWorkflowSelectsRemainingDraftAndItsInput() throws {
        let suite = "WorkflowWorkspaceDeletedDiscard.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = workflow("First")
        let second = workflow("Second")
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([first, second])
        let workspace = BuiltInAutomationWorkspace(defaults: defaults)
        workspace.select(second.id)
        workspace.source = "Second input"
        workspace.select(first.id)
        workspace.workflow.name = "First unsaved"
        try BuiltInAutomationLibrary(defaults: defaults).remove(first.id)

        try workspace.discardSelection()

        #expect(workspace.drafts == [second])
        #expect(workspace.workflow == second)
        #expect(workspace.source == "Second input")
        #expect(!workspace.hasUnsavedChanges)

        workspace.workflow.name = "Second unsaved"
        try BuiltInAutomationLibrary(defaults: defaults).remove(second.id)
        try workspace.discardSelection()
        #expect(workspace.workflow.id != second.id)
        #expect(workspace.drafts == [workspace.workflow])
        #expect(workspace.source.isEmpty)
        #expect(!workspace.hasUnsavedChanges)
    }

    @Test func unreadableSavedDefinitionsMakeDiscardPreserveAllLocalWork() throws {
        let suite = "WorkflowWorkspaceUnreadableDiscard.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = workflow("Original")
        try BuiltInAutomationLibrary(defaults: defaults).save(original)
        let workspace = BuiltInAutomationWorkspace(source: "Temporary input", defaults: defaults)
        workspace.workflow.name = "Local unsaved"
        let draft = workspace.workflow
        let readable = try #require(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey))
        let unreadable = Data("unreadable".utf8)
        defaults.set(unreadable, forKey: BuiltInAutomationLibrary.defaultsKey)

        #expect(throws: BuiltInAutomationFailure.unreadableWorkflows) { try workspace.discardSelection() }

        #expect(workspace.workflow == draft)
        #expect(workspace.drafts == [draft])
        #expect(workspace.changedDrafts == [draft])
        #expect(workspace.source == "Temporary input")
        #expect(defaults.data(forKey: BuiltInAutomationLibrary.defaultsKey) == unreadable)

        defaults.set(readable, forKey: BuiltInAutomationLibrary.defaultsKey)
        try workspace.discardSelection()
        #expect(workspace.workflow == original)
        #expect(workspace.library.failure == nil)
        #expect(workspace.source == "Temporary input")
    }

    @Test(arguments: ["saveSelection", "saveAll", "remove", "move", "discard"])
    func refreshKeepsAnExternallyDeletedWorkflowWithUnappliedRuleTextReachable(_ operation: String) async throws {
        let suite = "WorkflowWorkspacePendingRules.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = workflow("Alpha")
        let beta = workflow("Beta")
        let gamma = workflow("Gamma")
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([alpha, beta, gamma])
        let workspace = BuiltInAutomationWorkspace(defaults: defaults)
        let editor = WorkflowStepsEditorState()
        workspace.select(beta.id)
        workspace.source = "Beta temporary input"
        editor.prepare(beta.id, steps: beta.steps)
        let ruleDraft = try #require(editor.draft(for: beta.id))
        ruleDraft.setMode(.syntax)
        await ruleDraft.prepareSourceIfNeeded()
        let pendingText = "# keep this edit\nuppercase()\n"
        ruleDraft.updateSource(pendingText)
        #expect(!workspace.isDirty(beta), "The visual definition alone has not changed")
        workspace.select(alpha.id)
        workspace.workflow.name = "Alpha edit"
        try BuiltInAutomationLibrary(defaults: defaults).remove(beta.id)
        let protected = editor.unappliedWorkflowIDs

        switch operation {
        case "saveSelection": try workspace.saveSelection(preservingDraftIDs: protected)
        case "saveAll": try workspace.saveAll(preservingDraftIDs: protected)
        case "remove": try workspace.remove(gamma.id, preservingDraftIDs: protected)
        case "move": try workspace.move(gamma.id, before: alpha.id, preservingDraftIDs: protected)
        case "discard": try workspace.discardSelection(preservingDraftIDs: protected)
        default: Issue.record("Unexpected fixture operation")
        }

        #expect(workspace.drafts.contains(beta))
        #expect(workspace.changedDrafts.contains(beta))
        #expect(!workspace.library.workflows.contains { $0.id == beta.id })
        workspace.select(beta.id)
        editor.prepare(beta.id, steps: workspace.workflow.steps)
        #expect(workspace.workflow == beta)
        #expect(workspace.source == "Beta temporary input")
        #expect(ruleDraft.source.utf8.elementsEqual(pendingText.utf8))
        #expect(ruleDraft.hasUnappliedChanges)

        // The preserved sidebar entry lets the user apply and explicitly save
        // the text again, rather than leaving an unreachable pending draft.
        let parsedResult = await ruleDraft.parseSource()
        let parsed = try #require(parsedResult)
        workspace.workflow.steps = parsed
        ruleDraft.acceptApplied(parsed)
        try workspace.saveSelection(preservingDraftIDs: editor.unappliedWorkflowIDs)
        #expect(!editor.hasUnappliedChanges)
        #expect(!workspace.isDirty(workspace.workflow))
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows.first { $0.id == beta.id }?.steps == parsed)
    }

    @Test(arguments: [false, true])
    func explicitDiscardOrRemovalStillHandlesItsTargetWhileProtectingOtherRuleDrafts(remove: Bool) async throws {
        let suite = "WorkflowWorkspaceExplicitPendingAction.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alpha = workflow("Alpha")
        let beta = workflow("Beta")
        let gamma = workflow("Gamma")
        try BuiltInAutomationLibrary(defaults: defaults).saveAll([alpha, beta, gamma])
        let workspace = BuiltInAutomationWorkspace(defaults: defaults)
        let editor = WorkflowStepsEditorState()
        for definition in [beta, gamma] {
            editor.prepare(definition.id, steps: definition.steps)
            let draft = try #require(editor.draft(for: definition.id))
            draft.setMode(.syntax)
            await draft.prepareSourceIfNeeded()
            draft.updateSource("uppercase()\n")
        }
        let otherWindow = BuiltInAutomationLibrary(defaults: defaults)
        try otherWindow.remove(beta.id)
        try otherWindow.remove(gamma.id)
        workspace.select(beta.id)

        if remove {
            try workspace.remove(beta.id, preservingDraftIDs: editor.unappliedWorkflowIDs)
            editor.forget(beta.id)
        } else {
            try workspace.discardSelection(preservingDraftIDs: editor.unappliedWorkflowIDs)
            editor.discard(beta.id)
        }

        #expect(!workspace.drafts.contains { $0.id == beta.id })
        #expect(workspace.drafts.contains(gamma))
        #expect(workspace.isDirty(gamma))
        #expect(editor.unappliedWorkflowIDs == [gamma.id])
        workspace.select(gamma.id)
        #expect(workspace.workflow == gamma)
        #expect(editor.draft(for: gamma.id)?.source == "uppercase()\n")
    }

    private func workflow(_ name: String, trigger: BuiltInAutomationTrigger = .manual) -> BuiltInAutomationWorkflow {
        .init(name: name, steps: [.init(operation: .trim)], trigger: trigger)
    }
}
