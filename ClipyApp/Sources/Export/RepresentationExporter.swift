/// Explicit single-representation export (V2-07 §4.1.1). AppKit owns the
/// destination choice; no History mutation or content conversion is involved.
import AppKit
import Foundation
import HistoryCore
import UniformTypeIdentifiers

@MainActor
enum RepresentationExporter {
    static func saveAs(
        _ representation: HistoryRepresentation,
        for window: NSWindow
    ) async -> Result<Void, RepresentationExportFailure> {
        guard !Task.isCancelled else { return .success(()) }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFileName(for: representation.typeIdentifier)
        panel.message = representation.typeIdentifier
        // A sheet keeps the floating panel's existing public attachedSheet
        // focus-loss handling in charge while the user chooses a destination.
        let response = await withTaskCancellationHandler {
            guard !Task.isCancelled else { return NSApplication.ModalResponse.cancel }
            return await panel.beginSheetModal(for: window)
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
        panel.orderOut(nil)
        guard !Task.isCancelled, response == .OK,
              let destination = panel.url else { return .success(()) }
        let writeTask = Task.detached(priority: .userInitiated) {
            write(representation.bytes, to: destination)
        }
        return await withTaskCancellationHandler {
            await writeTask.value
        } onCancel: {
            writeTask.cancel()
        }
    }

    static func suggestedFileName(
        for typeIdentifier: String, bundle: Bundle = .main
    ) -> String {
        let base = bundle.localizedString(forKey: "Clipboard", value: "Clipboard", table: "RepresentationExport")
        // Clipboard encoding identifiers need not have filesystem tags in
        // the system type database. Name their unchanged bytes as text;
        // this is not a conversion or a semantic preview of opaque formats.
        let suffix: String
        switch typeIdentifier {
        case "public.plain-text", "public.utf8-plain-text",
             "public.utf16-plain-text", "public.utf16-external-plain-text":
            suffix = "txt"
        default:
            suffix = UTType(typeIdentifier)?.preferredFilenameExtension ?? "bin"
        }
        return base + "." + suffix
    }

    nonisolated static func write(
        _ bytes: Data, to destination: URL
    ) -> Result<Void, RepresentationExportFailure> {
        // Cancellation can prevent a write before it begins. An atomic write
        // already in progress is not rolled back on later cancellation.
        guard !Task.isCancelled else { return .success(()) }
        do {
            // The save panel owns overwrite confirmation. Atomic replacement
            // prevents a failed write from leaving a truncated chosen file.
            try bytes.write(to: destination, options: .atomic)
            return .success(())
        } catch {
            return .failure(.writeFailed)
        }
    }
}
