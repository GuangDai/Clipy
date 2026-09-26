import Foundation
@testable import ClipyApp
import Testing

@MainActor
struct BuiltInAutomationTransferTests {
    @Test func formattedDefinitionRoundTripsEveryBranchAndScopeWithoutInput() throws {
        var workflow = BuiltInAutomationWorkflow(name: "Shared workflow", steps: [
            .init(operation: .conditional, find: "TODO", thenSteps: [
                .init(operation: .replace, find: "é", replacement: "e\u{301}"), .init(operation: .notify)
            ], otherwiseSteps: [.init(operation: .trim)])
        ], trigger: .both)
        workflow.scope = .init(source: .history, applications: "org.telegram.desktop", historyLimit: 25,
                               timeRange: .custom, startDate: Date(timeIntervalSince1970: 100),
                               endDate: Date(timeIntervalSince1970: 200))
        let data = try BuiltInAutomationTransfer.export(workflow)
        let decoded = try BuiltInAutomationTransfer.decode(data)
        #expect(decoded == workflow)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["format", "version", "workflow"])
        #expect(String(decoding: data, as: UTF8.self).contains("\n  \"format\""))
    }

    @Test func importingCreatesAnIndependentManualDraftWithoutSavingOrReplacingAnything() throws {
        let suite = "WorkflowTransfer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = BuiltInAutomationWorkflow(name: "Existing", steps: [.init(operation: .trim)], trigger: .both)
        let library = BuiltInAutomationLibrary(defaults: defaults)
        try library.save(original)
        let workspace = BuiltInAutomationWorkspace(defaults: defaults)
        workspace.source = "private temporary test input"
        let data = try BuiltInAutomationTransfer.export(original)
        let imported = try BuiltInAutomationTransfer.decode(data)
        workspace.add(imported.duplicated(named: imported.name))
        #expect(workspace.workflow.id != original.id)
        #expect(workspace.workflow.steps[0].id != original.steps[0].id)
        #expect(workspace.workflow.trigger == .manual)
        #expect(workspace.source.isEmpty)
        #expect(!String(decoding: data, as: UTF8.self).contains("private temporary test input"))
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows == [original])
        try workspace.saveSelection()
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows.count == 2)
        #expect(BuiltInAutomationLibrary(defaults: defaults).workflows.first == original)
    }

    @Test func invalidFormatVersionAndDefinitionsAreRejectedBeforeImport() throws {
        let valid = BuiltInAutomationWorkflow(name: "Valid", steps: [.init(operation: .trim)])
        let data = try BuiltInAutomationTransfer.export(valid)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 99
        #expect(throws: BuiltInAutomationTransfer.Failure.unsupported) {
            try BuiltInAutomationTransfer.decode(JSONSerialization.data(withJSONObject: object))
        }
        object["version"] = 1
        var definition = try #require(object["workflow"] as? [String: Any])
        definition["name"] = "   "
        object["workflow"] = definition
        #expect(throws: BuiltInAutomationTransfer.Failure.invalidDefinition(.invalidWorkflow)) {
            try BuiltInAutomationTransfer.decode(JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: BuiltInAutomationTransfer.Failure.unreadable) {
            try BuiltInAutomationTransfer.decode(Data("not json".utf8))
        }
        #expect(throws: BuiltInAutomationTransfer.Failure.tooLarge) {
            try BuiltInAutomationTransfer.decode(Data(repeating: 0, count: BuiltInAutomationTransfer.maximumFileBytes + 1))
        }
    }

    @Test func fileReadEnforcesLimitAndReturnsAllBytesIncludingExactLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkflowTransfer-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data(repeating: 65, count: 131_072)
        try data.write(to: url)
        #expect(try BuiltInAutomationTransfer.read(url, maximumBytes: data.count) == data)
        #expect(throws: BuiltInAutomationTransfer.Failure.tooLarge) {
            try BuiltInAutomationTransfer.read(url, maximumBytes: data.count - 1)
        }
    }
}
