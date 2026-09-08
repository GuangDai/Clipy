/// V2-07 §6.3: separate logical, filesystem, derived-cache and process-memory
/// facts. These on-demand reads never schedule retention or cache eviction.
import AppKit
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
    @State private var showsDiagnostics = false
    @State private var folderCopyNotice: String?
    @State private var backupCopyNotice: String?

    var body: some View {
        Form {
            backupSection
            storageSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        // Keep independent fact reads and backup cancellation owned here.
        .task(id: refreshGeneration) { await refreshLogicalBytes() }
        .task(id: refreshGeneration) { await refreshAllocatedBytes() }
        .task(id: refreshGeneration) { await refreshProcessMemory() }
        .onDisappear { backupTask?.cancel() }
    }

    private var storageSection: some View {
        Section {
            LabeledContent(AutomationMaintenancePresentation.text("Clipboard Content")) {
                byteValue(logicalBytes, failed: logicalFailed)
                    .monospacedDigit()
                    .accessibilityIdentifier("clipy.settings.maintenance.logical-bytes")
            }
            LabeledContent(AutomationMaintenancePresentation.text("Space on Disk")) {
                byteValue(allocatedBytes, failed: allocatedFailed)
                    .monospacedDigit()
                    .accessibilityIdentifier("clipy.settings.maintenance.folder-bytes")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(AutomationMaintenancePresentation.text("History Folder"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(location.directoryPath)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("clipy.settings.maintenance.folder-path")
                ViewThatFits(in: .horizontal) {
                    HStack { revealFolderButton; copyFolderButton }
                    VStack(alignment: .leading, spacing: 8) { revealFolderButton; copyFolderButton }
                }
                if let folderCopyNotice {
                    Text(AutomationMaintenancePresentation.text(folderCopyNotice))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("clipy.settings.maintenance.folder-copy-notice")
                }
            }
            Button(MaintenanceSettingsCopy.text("Refresh")) { refreshGeneration += 1 }
                .accessibilityIdentifier("clipy.settings.maintenance.refresh")
        } header: {
            Text(AutomationMaintenancePresentation.text("Storage"))
        } footer: {
            Text(AutomationMaintenancePresentation.text(
                "Content includes retained revisions. Disk space also includes the files Clipy needs to keep your history."
            ))
        }
    }

    private var revealFolderButton: some View {
        Button(MaintenanceSettingsCopy.text("Show in Finder")) { location.reveal() }
            .accessibilityIdentifier("clipy.settings.maintenance.reveal")
    }

    private var copyFolderButton: some View {
        Button(AutomationMaintenancePresentation.text("Copy Path")) {
            folderCopyNotice = copyPath(location.directoryPath)
        }
        .accessibilityIdentifier("clipy.settings.maintenance.copy-path")
    }

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsDiagnostics) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(MaintenanceSettingsCopy.logicalDisclosure())
                        .font(.caption).foregroundStyle(.secondary)
                    Text(MaintenanceSettingsCopy.folderDisclosure())
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("clipy.settings.maintenance.folder-disclosure")
                    Divider()
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
                    Text(MaintenanceSettingsCopy.memoryDisclosure())
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent(MaintenanceSettingsCopy.text("Derived Disk Cache")) {
                        Text(MaintenanceSettingsCopy.text("Not Used"))
                            .accessibilityIdentifier("clipy.settings.maintenance.derived-cache")
                    }
                    Text(MaintenanceSettingsCopy.cacheDisclosure())
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } label: {
                Label(AutomationMaintenancePresentation.text("Diagnostics"), systemImage: "waveform.path.ecg")
            }
            .accessibilityIdentifier("clipy.settings.maintenance.diagnostics")
        }
    }

    private var backupSection: some View {
        Section {
            Label(AutomationMaintenancePresentation.text("Save a Copy of Your History"), systemImage: "externaldrive.badge.plus")
                .font(.headline)
            Text(AutomationMaintenancePresentation.text("Choose a folder to keep a complete backup of your saved clipboard items."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(MaintenanceSettingsCopy.text("Back Up History…")) {
                guard backupTask == nil else { return }
                backupCopyNotice = nil
                backupTask = Task {
                    await backup.backUp(history: history, location: location)
                    backupTask = nil
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(backupTask != nil)
            .accessibilityIdentifier("clipy.settings.maintenance.backup")
            if backup.isWorking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(MaintenanceSettingsCopy.text("Backing up history…"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button(MaintenanceSettingsCopy.text("Cancel")) { backupTask?.cancel() }
                    .accessibilityIdentifier("clipy.settings.maintenance.backup-cancel")
            }
            if let outcome = backup.outcome {
                Text(MaintenanceSettingsCopy.backupStatus(outcome))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clipy.settings.maintenance.backup-status")
            }
            if let completedDirectory = backup.completedDirectory {
                Text(completedDirectory.path)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("clipy.settings.maintenance.backup-path")
                Button(MaintenanceSettingsCopy.text("Show Backup in Finder")) { backup.reveal(using: location) }
                    .accessibilityIdentifier("clipy.settings.maintenance.backup-reveal")
                Button(AutomationMaintenancePresentation.text("Copy Path")) {
                    backupCopyNotice = copyPath(completedDirectory.path)
                }
                .accessibilityIdentifier("clipy.settings.maintenance.backup-copy-path")
                if let backupCopyNotice {
                    Text(AutomationMaintenancePresentation.text(backupCopyNotice))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("clipy.settings.maintenance.backup-copy-notice")
                }
            }
        } header: {
            Text(AutomationMaintenancePresentation.text("Backup"))
        } footer: {
            Text(MaintenanceSettingsCopy.backupDisclosure())
                .accessibilityIdentifier("clipy.settings.maintenance.backup-disclosure")
        }
    }

    private func copyPath(_ path: String) -> String {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(path, forType: .string) ? "Path copied." : "Could not copy the path."
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
