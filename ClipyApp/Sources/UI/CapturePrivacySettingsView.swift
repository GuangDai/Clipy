import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Select applications by name; the existing capture preference continues to
/// store only bundle identifiers. Selection reads bundle metadata, never runs
/// the application or reads any clipboard content (V2-07 §6).
struct CapturePrivacySettingsView: View {
    @State private var ignoreList = CaptureIgnoreList()
    @State private var isChoosingApplications = false
    @State private var showsManualEntry = false
    @State private var identifierDraft = ""
    @State private var selectionFailed = false

    var body: some View {
        Section {
            ForEach(ignoreList.bundleIDs, id: \.self) { identifier in
                IgnoredApplicationRow(identifier: identifier) {
                    ignoreList.remove(identifier)
                    ignoreList.store(to: .standard)
                }
            }
            Button(CapturePrivacyCopy.text("Add Applications…"), systemImage: "plus") {
                selectionFailed = false
                isChoosingApplications = true
            }
            .accessibilityIdentifier("clipy.settings.privacy.choose-applications")
            .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications", isDirectory: true))
            .fileImporter(isPresented: $isChoosingApplications,
                          allowedContentTypes: [.application], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    selectionFailed = Self.addApplications(urls, to: &ignoreList) > 0
                    ignoreList.store(to: .standard)
                case .failure:
                    selectionFailed = true
                }
            }
            if selectionFailed {
                Text(CapturePrivacyCopy.text("Some applications could not be added. You can enter their bundle identifiers below."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(CapturePrivacyCopy.text("Enter a Bundle Identifier"), isExpanded: $showsManualEntry) {
                HStack {
                    TextField(SettingsCopy.text("Bundle identifier, e.g. com.1password.1password"), text: $identifierDraft)
                        .accessibilityIdentifier("clipy.settings.privacy.bundle-identifier")
                    Button(SettingsCopy.text("Add")) {
                        guard ignoreList.add(identifierDraft) else { return }
                        ignoreList.store(to: .standard)
                        identifierDraft = ""
                    }
                    .accessibilityIdentifier("clipy.settings.privacy.add-ignore")
                    .disabled(!canAddIdentifier)
                }
            }
            .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.settings.privacy.manual-entry"))
        } header: {
            Text(SettingsCopy.text("Privacy"))
                .accessibilityIdentifier("clipy.settings.privacy.ignored-list")
        } footer: {
            Text(SettingsCopy.text("Clipboard contents from these apps are never recorded."))
        }
        .onAppear { ignoreList = CaptureIgnoreList.load(from: .standard) }
    }

    private var canAddIdentifier: Bool {
        var edited = ignoreList
        return edited.add(identifierDraft)
    }

    /// Returns only the count that could not be identified. An already-listed
    /// application is a successful no-op; one bad selection never removes other
    /// selected or previously ignored applications.
    static func addApplications(_ urls: [URL], to list: inout CaptureIgnoreList) -> Int {
        var failures = 0
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let identifier = Bundle(url: url)?.bundleIdentifier else {
                failures += 1
                continue
            }
            if !list.ignores(identifier), !list.add(identifier) { failures += 1 }
        }
        return failures
    }
}

private struct IgnoredApplicationRow: View {
    let identifier: String
    let onRemove: () -> Void
    @State private var name: String?
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.dashed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
            Text(verbatim: name ?? identifier)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(identifier)
            Spacer(minLength: 8)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(SettingsCopy.removeIgnoredApp(name ?? identifier))
            .accessibilityIdentifier("clipy.settings.privacy.application." + identifier + ".remove")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.settings.privacy.application." + identifier)
        .task(id: identifier) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return }
            name = FileManager.default.displayName(atPath: url.path)
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}

enum CapturePrivacyCopy {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "CapturePrivacy")
    }
}
