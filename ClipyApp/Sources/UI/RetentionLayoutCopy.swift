import Foundation
import HistoryCore

/// Concise copy for the configured-policy summary and progressive disclosure.
enum RetentionLayoutCopy {
    static var currentPolicy: String { text("current", "Currently applied") }
    static var pendingChanges: String { text("pending", "Changes not yet applied") }
    static var automaticPolicies: String { text("automatic", "Automatic cleanup") }
    static var countDetails: String { text("count-details", "How the item limit works") }
    static var policyDetails: String { text("policy-details", "When cleanup happens") }

    static func countSummary(
        _ configuration: HistoryRetentionConfiguration,
        bundle: Bundle = .main, locale: Locale = .current
    ) -> String {
        guard let maximum = configuration.maximumUnpinnedItems else {
            return text("count-off", "No item count limit", bundle: bundle)
        }
        return String(format: text("count-on", "Unpinned item limit: %@", bundle: bundle),
            locale: locale, maximum.formatted(.number.locale(locale)))
    }

    static func policySummary(_ configuration: HistoryRetentionConfiguration, bundle: Bundle = .main) -> String {
        var enabled: [String] = []
        if configuration.policies.age != nil { enabled.append(text("age", "Age", bundle: bundle)) }
        if configuration.policies.storage != nil { enabled.append(text("storage", "Storage", bundle: bundle)) }
        if configuration.policies.revisions != nil { enabled.append(text("revisions", "Revisions", bundle: bundle)) }
        guard !enabled.isEmpty else {
            return text("policies-off", "Age, storage and revision limits are off.", bundle: bundle)
        }
        return String(format: text("policies-on", "Cleanup limits: %@", bundle: bundle),
            enabled.joined(separator: " · "))
    }

    private static func text(_ key: String, _ fallback: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key, value: fallback, table: "RetentionLayout")
    }
}
