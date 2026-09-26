import AppKit
import HistoryCore
import Observation

/// Search names come from installed application metadata, never from guessing
/// words in a bundle identifier or loading the entire clipboard history.
@MainActor @Observable
final class SourceApplicationSearchResolver {
    struct Application: Identifiable, Equatable, Sendable {
        let bundleID: String
        let displayName: String
        let names: [String]
        var id: String { bundleID }

        init(bundleID: String, displayName: String, names: [String] = []) {
            self.bundleID = bundleID
            self.displayName = displayName
            self.names = [displayName] + names
        }
    }

    struct Resolution {
        let expression: HistorySearchExpression
        let unresolvedNames: [String]
    }

    private(set) var applications: [Application] = []
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private let usesProvidedApplications: Bool
    @ObservationIgnored private var preparation: Task<Void, Never>?

    /// Injected applications make name admission independent of the machine's
    /// installed apps in tests. Production construction performs no file I/O.
    init(applications: [Application]? = nil) {
        usesProvidedApplications = applications != nil
        if let applications {
            self.applications = Self.consolidated(applications)
            prepared = true
        }
    }

    /// Cached lazy metadata per browsing surface. Superseding searches share
    /// the in-flight read without making the next keystroke scan again.
    /// Only immutable names/IDs cross back from the background file work.
    /// Opening the application chooser may refresh this list after installs;
    /// active History requests keep their already-resolved exact IDs.
    func prepare(refresh: Bool = false) async {
        guard !usesProvidedApplications else { return }
        if let preparation {
            await preparation.value
            return
        }
        guard !prepared || refresh else { return }
        if preparation == nil {
            let directories = FileManager.default.urls(
                for: .applicationDirectory, in: [.userDomainMask, .localDomainMask, .systemDomainMask]
            )
            let runningApplications = NSWorkspace.shared.runningApplications
            let runningURLs = runningApplications.compactMap(\.bundleURL)
            let running = runningApplications.compactMap { application -> Application? in
                guard let id = application.bundleIdentifier,
                      let name = application.localizedName, !name.isEmpty else { return nil }
                return Application(bundleID: id, displayName: name)
            }
            let loading = Task.detached(priority: .utility) {
                Self.consolidated(running + runningURLs.compactMap { Self.application(at: $0) }
                                  + Self.applications(in: directories))
            }
            // Only this task publishes the shared read. Concurrent waiters
            // cannot clear or overwrite a newer explicit refresh.
            preparation = Task { [weak self] in
                let applications = await loading.value
                guard let self else { return }
                self.applications = applications
                self.prepared = true
                self.preparation = nil
            }
        }
        await preparation?.value
    }

    /// Name fragments apply only to real names (Brave also finds Brave Browser).
    /// Choosing a suggestion or writing source-id: remains an exact ID match.
    func identifiers(matching name: String) -> [String] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return applications.filter { application in
            application.bundleID.compare(query, options: .caseInsensitive) == .orderedSame
                || application.names.contains { $0.range(of: query, options: .caseInsensitive) != nil }
        }.map(\.bundleID)
    }

    func resolve(_ expression: HistorySearchExpression) -> Resolution {
        var unresolved: [String] = []
        let resolved = expression.replacingApplicationTerms { name in
            let identifiers = self.identifiers(matching: name)
            if identifiers.isEmpty, !unresolved.contains(name) { unresolved.append(name) }
            return identifiers
        }
        return Resolution(expression: resolved, unresolvedNames: unresolved)
    }

    /// The same real bundle metadata is usable by an explicit app picker.
    /// Bundle.object(forInfoDictionaryKey:) includes localized InfoPlist values;
    /// retain the original values too so both localized and original names work.
    nonisolated static func application(at url: URL) -> Application? {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier, !identifier.isEmpty else { return nil }
        let fileName = FileManager.default.displayName(atPath: url.path)
        let displayedFileName = fileName.lowercased().hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName
        let localized = ["CFBundleDisplayName", "CFBundleName"].compactMap {
            bundle.object(forInfoDictionaryKey: $0) as? String
        }.filter { !$0.isEmpty }
        let original = ["CFBundleDisplayName", "CFBundleName"].compactMap {
            bundle.infoDictionary?[$0] as? String
        }.filter { !$0.isEmpty }
        return Application(bundleID: identifier,
                           displayName: localized.first ?? displayedFileName,
                           names: localized + original + [displayedFileName, url.deletingPathExtension().lastPathComponent])
    }

    /// Enumerate only the standard Applications directories; application and
    /// other package contents, hidden entries and symlink descendants are not
    /// traversed. Running applications cover apps opened from other locations.
    nonisolated static func applications(in directories: [URL]) -> [Application] {
        var result: [Application] = []
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if Task.isCancelled { return result }
                if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                    enumerator.skipDescendants()
                    if let application = application(at: url) { result.append(application) }
                }
            }
        }
        return result
    }

    nonisolated private static func consolidated(_ applications: [Application]) -> [Application] {
        var indexed: [String: Application] = [:]
        for application in applications {
            let key = application.bundleID
            if let existing = indexed[key] {
                indexed[key] = Application(bundleID: existing.bundleID, displayName: existing.displayName,
                                           names: Array(Set(existing.names + application.names)).sorted())
            } else { indexed[key] = application }
        }
        return indexed.values.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }
    }
}
