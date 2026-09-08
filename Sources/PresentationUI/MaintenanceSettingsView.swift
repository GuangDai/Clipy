/// V2-07 §6.3: separate logical, filesystem, derived-cache and process-memory
/// facts. These on-demand reads never schedule retention or cache eviction.
import HistoryCore
import SwiftUI

struct MaintenanceSettingsView: View {
    let history: any ClipboardHistory
    let location: StorageLocationSettings

    @Environment(\.locale) private var locale
    @State private var backup = HistoryBackupSettingsModel()
    @State private var backupTask: Task<Void, Never>?
    @State private var refreshGeneration = 0
    @State private var logicalBytes: Int?
    @State private var logicalFailed = false
    @State private var allocatedBytes: Int?
    @State private var allocatedFailed = false
    @State private var processMemory: ProcessMemoryUsage?
    @State private var processMemoryFailed = false

    var body: some View {
        Form {
            backupSection
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
            Section {
                LabeledContent(MaintenanceSettingsCopy.text("Derived Disk Cache")) {
                    Text(MaintenanceSettingsCopy.text("Not Used"))
                        .accessibilityIdentifier("clipy.settings.maintenance.derived-cache")
                }
            } footer: {
                Text(MaintenanceSettingsCopy.cacheDisclosure())
            }
            Section {
                LabeledContent(MaintenanceSettingsCopy.text("Resident Memory (RSS)")) {
                    byteValue(processMemory?.residentBytes, failed: processMemoryFailed)
                        .accessibilityIdentifier("clipy.settings.maintenance.resident-bytes")
                }
                LabeledContent(MaintenanceSettingsCopy.text("Peak Resident Memory")) {
                    byteValue(processMemory?.peakResidentBytes, failed: processMemoryFailed)
                        .accessibilityIdentifier("clipy.settings.maintenance.peak-resident-bytes")
                }
                LabeledContent(MaintenanceSettingsCopy.text("Memory Footprint")) {
                    byteValue(processMemory?.footprintBytes, failed: processMemoryFailed)
                        .accessibilityIdentifier("clipy.settings.maintenance.footprint-bytes")
                }
            } footer: {
                Text(MaintenanceSettingsCopy.memoryDisclosure())
            }
            Button(MaintenanceSettingsCopy.text("Refresh")) {
                refreshGeneration += 1
            }
            .accessibilityIdentifier("clipy.settings.maintenance.refresh")
        }
        .formStyle(.grouped)
        // Separate tasks let each fact succeed while another is slow or
        // unavailable. SwiftUI cancels them on refresh and tab disappearance.
        .task(id: refreshGeneration) { await refreshLogicalBytes() }
        .task(id: refreshGeneration) { await refreshAllocatedBytes() }
        .task(id: refreshGeneration) { await refreshProcessMemory() }
        .onDisappear { backupTask?.cancel() }
    }

    private var backupSection: some View {
        Section {
            HStack {
                Button(MaintenanceSettingsCopy.text("Back Up History…")) {
                    guard backupTask == nil else { return }
                    backupTask = Task {
                        await backup.backUp(history: history, location: location)
                        backupTask = nil
                    }
                }
                .disabled(backupTask != nil)
                .accessibilityIdentifier("clipy.settings.maintenance.backup")
                if backup.isWorking {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(MaintenanceSettingsCopy.text("Backing up history…"))
                    Button(MaintenanceSettingsCopy.text("Cancel")) { backupTask?.cancel() }
                        .accessibilityIdentifier("clipy.settings.maintenance.backup-cancel")
                }
            }
            if let outcome = backup.outcome {
                Text(MaintenanceSettingsCopy.backupStatus(outcome))
                    .font(.callout)
                    .accessibilityIdentifier("clipy.settings.maintenance.backup-status")
            }
            if backup.completedDirectory != nil {
                Button(MaintenanceSettingsCopy.text("Show Backup in Finder")) {
                    backup.reveal(using: location)
                }
                .accessibilityIdentifier("clipy.settings.maintenance.backup-reveal")
            }
        } footer: {
            Text(MaintenanceSettingsCopy.backupDisclosure())
                .accessibilityIdentifier("clipy.settings.maintenance.backup-disclosure")
        }
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

    private func refreshProcessMemory() async {
        guard !Task.isCancelled else { return }
        processMemory = nil
        processMemoryFailed = false
        do {
            let memory = try await location.processMemory()
            guard !Task.isCancelled else { return }
            processMemory = memory
        } catch {
            guard !Task.isCancelled else { return }
            processMemoryFailed = true
        }
    }
}
