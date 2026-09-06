/// V2-07 §6.3: independent on-demand logical and filesystem facts. Neither
/// read performs a History action or schedules retention work.
import HistoryCore
import SwiftUI

struct MaintenanceSettingsView: View {
    let history: any ClipboardHistory
    let location: StorageLocationSettings

    @Environment(\.locale) private var locale
    @State private var refreshGeneration = 0
    @State private var logicalBytes: Int?
    @State private var logicalFailed = false
    @State private var allocatedBytes: Int?
    @State private var allocatedFailed = false

    var body: some View {
        Form {
            Section {
                LabeledContent(MaintenanceSettingsCopy.text("Logical Content Size")) {
                    byteValue(logicalBytes, failed: logicalFailed)
                        .accessibilityIdentifier("clipy.settings.maintenance.logical-bytes")
                }
            } footer: {
                Text(MaintenanceSettingsCopy.logicalDisclosure())
            }
            Section {
                LabeledContent(MaintenanceSettingsCopy.text("Store Folder Size")) {
                    byteValue(allocatedBytes, failed: allocatedFailed)
                        .accessibilityIdentifier("clipy.settings.maintenance.folder-bytes")
                }
                Text(location.directoryPath)
                    .font(.caption)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("clipy.settings.maintenance.folder-path")
                Button(MaintenanceSettingsCopy.text("Show in Finder")) {
                    location.reveal()
                }
                .accessibilityIdentifier("clipy.settings.maintenance.reveal")
            } footer: {
                Text(MaintenanceSettingsCopy.folderDisclosure())
                    .accessibilityIdentifier("clipy.settings.maintenance.folder-disclosure")
            }
            Button(MaintenanceSettingsCopy.text("Refresh")) {
                refreshGeneration += 1
            }
            .accessibilityIdentifier("clipy.settings.maintenance.refresh")
        }
        .formStyle(.grouped)
        // Separate tasks let either fact succeed while the other is slow or
        // unavailable. SwiftUI cancels both on refresh and tab disappearance.
        .task(id: refreshGeneration) { await refreshLogicalBytes() }
        .task(id: refreshGeneration) { await refreshAllocatedBytes() }
    }

    @ViewBuilder
    private func byteValue(_ bytes: Int?, failed: Bool) -> some View {
        if let bytes {
            Text(HistoryUsageCopy.contentBytes(bytes, locale: locale))
        } else if failed {
            Text(MaintenanceSettingsCopy.text("Unavailable"))
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(MaintenanceSettingsCopy.text("Loading size…"))
        }
    }

    private func refreshLogicalBytes() async {
        guard !Task.isCancelled else { return }
        logicalBytes = nil
        logicalFailed = false
        do {
            let usage = try await history.usage()
            guard !Task.isCancelled else { return }
            logicalBytes = usage.totalContentBytes
        } catch {
            guard !Task.isCancelled else { return }
            logicalFailed = true
        }
    }

    private func refreshAllocatedBytes() async {
        guard !Task.isCancelled else { return }
        allocatedBytes = nil
        allocatedFailed = false
        do {
            let bytes = try await location.allocatedBytes()
            guard !Task.isCancelled else { return }
            allocatedBytes = bytes
        } catch {
            guard !Task.isCancelled else { return }
            allocatedFailed = true
        }
    }
}
