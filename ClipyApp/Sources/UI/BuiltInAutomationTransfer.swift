import Foundation
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A shareable definition has no test input, output, or History reference.
/// Import always creates a new manual draft; Save is still the only operation
/// that admits that definition for future automatic copies (V2-13).
enum BuiltInAutomationTransfer {
    static let maximumFileBytes = 4 * BuiltInAutomation.maximumBytes

    private struct FileContents: Codable {
        let format: String
        let version: Int
        let workflow: BuiltInAutomationWorkflow
    }

    enum Failure: Error, Equatable {
        case unreadable, tooLarge, unsupported, invalidDefinition(BuiltInAutomationFailure)

        var message: String {
            switch self {
            case .unreadable: "This file could not be read as a Clipy workflow. Choose a workflow JSON file."
            case .tooLarge: "Workflow files must be no larger than 4 MiB."
            case .unsupported: "This workflow file uses an unsupported format or version."
            case .invalidDefinition(let failure): failure.message
            }
        }
    }

    @MainActor static func export(_ workflow: BuiltInAutomationWorkflow) throws -> Data {
        var definition = workflow
        definition.name = workflow.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = BuiltInAutomationLibrary.validationFailure(for: definition) {
            throw Failure.invalidDefinition(failure)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(FileContents(format: "com.clipy.workflow", version: 1, workflow: definition))
        } catch {
            if let failure = BuiltInAutomation.definitionNestingFailure(for: error) { throw Failure.invalidDefinition(failure) }
            throw error
        }
        guard data.count <= maximumFileBytes else { throw Failure.tooLarge }
        _ = try decode(data)
        return data
    }

    @MainActor static func decode(_ data: Data) throws -> BuiltInAutomationWorkflow {
        guard data.count <= maximumFileBytes else { throw Failure.tooLarge }
        let contents: FileContents
        do { contents = try JSONDecoder().decode(FileContents.self, from: data) }
        catch {
            if let failure = BuiltInAutomation.definitionNestingFailure(for: error) { throw Failure.invalidDefinition(failure) }
            throw Failure.unreadable
        }
        guard contents.format == "com.clipy.workflow", contents.version == 1 else { throw Failure.unsupported }
        var definition = contents.workflow
        definition.name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let failure = BuiltInAutomationLibrary.validationFailure(for: definition) {
            throw Failure.invalidDefinition(failure)
        }
        return definition
    }

    /// Bound the file read itself, including files whose reported size changes.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        return data
    }
}

struct BuiltInAutomationFileDocument: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
    }
}

struct BuiltInAutomationImportReview: View {
    @Environment(\.locale) private var interfaceLocale
    let workflow: BuiltInAutomationWorkflow
    let bundle: Bundle
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    private func text(_ key: String) -> String { BuiltInAutomationCopy.text(key, bundle: bundle) }

    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 16) {
            Text(text("Import workflow")).font(.title2.weight(.semibold))
            Text(workflow.name).font(.headline).lineLimit(3).textSelection(.enabled)
            LabeledContent(text("Steps"), value: "\(BuiltInAutomationStepEditing.count(workflow.steps))")
            LabeledContent(text("Original trigger"), value: text(workflow.trigger.title))
            LabeledContent(text("Manual input"), value: text(workflow.scope.source.title))
            Text(text("Import creates a separate manual draft. Review its steps and save it before enabling automatic runs."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(text("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("clipy.workflow.import.cancel")
                Spacer()
                Button(text("Add as manual workflow")) { onImport(); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("clipy.workflow.import.confirm")
            }
        }
        .padding(24).frame(width: 440)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.workflow.import.review")
    }
}
