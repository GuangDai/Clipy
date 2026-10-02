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
            // Usage is a compact read-only summary, not five separate Form
            // rows above the controls the user came here to change.
            VStack(alignment: .leading, spacing: 8) {
                if let usage {
                    HStack(alignment: .top, spacing: 12) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { metrics(usage) }
                                .fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: 6) { metrics(usage) }
                        }
                        Spacer(minLength: 0)
                        Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help(HistoryUsageCopy.text("Refresh"))
                            .accessibilityLabel(HistoryUsageCopy.text("Refresh"))
                            .accessibilityIdentifier("clipy.settings.usage.refresh")
                    }
                } else if failed {
                    HStack {
                        Text(HistoryUsageCopy.text("Usage unavailable."))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("clipy.settings.usage.unavailable")
                        Button(HistoryUsageCopy.text("Retry"), action: onRefresh)
                            .accessibilityIdentifier("clipy.settings.usage.retry")
                    }
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
                .disclosureGroupStyle(AppDisclosureGroupStyle(identifier: "clipy.settings.usage.details"))
            }
        } header: {
            Text(HistoryUsageCopy.text("Retained History"))
        }
    }

    @ViewBuilder
    private func metrics(_ usage: HistoryUsage) -> some View {
        metric("Items", value: LocalizedCountPresentation.number(usage.itemCount, locale: locale), id: "item-count")
        metric("Pinned Items", value: LocalizedCountPresentation.number(usage.pinnedItemCount, locale: locale), id: "pinned-count")
        metric("Content Size", value: HistoryUsageCopy.contentBytes(usage.totalContentBytes, locale: locale), id: "content-bytes")
    }

    private func metric(_ label: String, value: String, id: String) -> some View {
        HStack(spacing: 6) {
            Text(HistoryUsageCopy.text(label)).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
                .accessibilityIdentifier("clipy.settings.usage." + id)
        }
    }
}

/// Presentation-only copy shared by these three Settings sections.
/// Product actions and permission/backup decisions stay with their owners.
enum AutomationMaintenancePresentation {
    static var bundle: Bundle { AppLocalization.bundle }

    static func text(_ key: String, bundle: Bundle? = nil) -> String {
        (bundle ?? Self.bundle).localizedString(
            forKey: key, value: key, table: "AutomationMaintenancePresentation"
        )
    }
}
