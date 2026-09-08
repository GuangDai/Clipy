/// On-demand retained History usage for the Retention settings surface.
/// The public read returns logical content bytes; this view neither queries
/// filesystem allocation nor installs another History observation stream.
import Foundation
import HistoryCore
import SwiftUI

struct HistoryUsageView: View {
    let usage: HistoryUsage?
    let failed: Bool
    let onRefresh: () -> Void

    @Environment(\.locale) private var locale
    @State private var showsSizeDetails = false

    var body: some View {
        Section {
            if let usage {
                LabeledContent(HistoryUsageCopy.text("Items")) {
                    Text(LocalizedCountPresentation.number(usage.itemCount, locale: locale))
                        .font(.headline).monospacedDigit()
                        .accessibilityIdentifier("clipy.settings.usage.item-count")
                }
                LabeledContent(HistoryUsageCopy.text("Pinned Items")) {
                    Text(LocalizedCountPresentation.number(usage.pinnedItemCount, locale: locale))
                        .monospacedDigit()
                        .accessibilityIdentifier("clipy.settings.usage.pinned-count")
                }
                LabeledContent(HistoryUsageCopy.text("Content Size")) {
                    Text(HistoryUsageCopy.contentBytes(usage.totalContentBytes, locale: locale))
                        .monospacedDigit()
                        .accessibilityIdentifier("clipy.settings.usage.content-bytes")
                }
                Button(HistoryUsageCopy.text("Refresh")) {
                    onRefresh()
                }
                .accessibilityIdentifier("clipy.settings.usage.refresh")
            } else if failed {
                Text(HistoryUsageCopy.text("Usage unavailable."))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("clipy.settings.usage.unavailable")
                Button(HistoryUsageCopy.text("Retry")) {
                    onRefresh()
                }
                .accessibilityIdentifier("clipy.settings.usage.retry")
            } else {
                ProgressView(HistoryUsageCopy.text("Loading usage…"))
                    .accessibilityIdentifier("clipy.settings.usage.loading")
            }
            DisclosureGroup(isExpanded: $showsSizeDetails) {
                Text(HistoryUsageCopy.disclosure())
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clipy.settings.usage.disclosure")
            } label: {
                Text(AutomationMaintenancePresentation.text("About Content Size"))
            }
            .accessibilityIdentifier("clipy.settings.usage.details")
        } header: {
            Text(HistoryUsageCopy.text("Retained History"))
        }
    }
}

/// Presentation-only copy shared by these three Settings sections.
/// Product actions and permission/backup decisions stay with their owners.
enum AutomationMaintenancePresentation {
    static let bundle = Bundle.main

    static func text(_ key: String, bundle: Bundle? = nil) -> String {
        (bundle ?? Self.bundle).localizedString(
            forKey: key, value: key, table: "AutomationMaintenancePresentation"
        )
    }
}
