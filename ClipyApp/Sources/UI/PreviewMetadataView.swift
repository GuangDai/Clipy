import Foundation
import HistoryCore
import SwiftUI

/// V2-11: content occupies the pane; copy provenance is secondary and the
/// full application breakdown appears only on disclosure. Reads are metadata
/// only and follow occurrence changes even when ContentVersion stays fixed.
struct PreviewMetadataView: View {
    let history: any ClipboardHistory
    let row: HistoryRow
    let sourceIcons: SourceIconStore?
    @Environment(\.locale) private var locale
    @State private var details: HistoryDetails?
    @State private var expanded = false
    @State private var failed = false
    @State private var retry = 0

    private struct Request: Equatable {
        let item: HistoryItemReference
        let copyCount: UInt64
        let lastCopiedAt: Date
        let retry: Int
    }

    private var currentDetails: HistoryDetails? {
        guard let details, details.item == row.item,
              details.occurrence.count == row.copyCount,
              details.occurrence.lastCopiedAt == row.lastCopiedAt else { return nil }
        return details
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SourceApplicationLabel(application: row.lastSource, store: sourceIcons, isInformation: true)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if row.copyCount > 1 {
                    Text(PreviewCopy.copyCount(row.copyCount, locale: locale))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            CopyTimeRow(label: "Last Copied", date: row.lastCopiedAt)
            if let details = currentDetails, row.copyCount > 1 {
                CopyTimeRow(label: "First Copied", date: details.occurrence.firstCopiedAt)
            }
            if row.sourceCount > 1 {
                DisclosureGroup(isExpanded: $expanded) {
                    if expanded {
                        CopySourcesView(history: history, row: row, sourceIcons: sourceIcons)
                            .id(row.copyCount)
                    }
                } label: {
                    Label(PreviewCopy.text("Copy Sources"), systemImage: "square.on.square")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("clipy.preview.sources")
            }
            if failed {
                Button(PreviewCopy.text("Retry Copy Information")) { retry += 1 }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: Request(item: row.item, copyCount: row.copyCount,
                          lastCopiedAt: row.lastCopiedAt, retry: retry)) {
            failed = false
            // A single copy needs only the row's last-copy facts. Details
            // supplies the first-copy time only when repeats are visible.
            guard row.copyCount > 1 else {
                details = nil
                return
            }
            do {
                let value = try await history.details(for: row.item.id)
                try Task.checkCancellation()
                guard value.item == row.item,
                      value.occurrence.count == row.copyCount,
                      value.occurrence.lastCopiedAt == row.lastCopiedAt else { return }
                details = value
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }

}

/// The expanded source area holds one page, and releases it when collapsed.
/// Repeated copies replace this child using the observed count, so a source
/// reordered by recency never joins the previous page's data.
private struct CopySourcesView: View {
    let history: any ClipboardHistory
    let row: HistoryRow
    let sourceIcons: SourceIconStore?
    @Environment(\.locale) private var locale
    @State private var offset = 0
    @State private var retry = 0
    @State private var page: HistoryCopySourcePage?
    @State private var loadedOffset: Int?
    @State private var failed = false

    private struct Request: Equatable {
        let offset: Int
        let retry: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let page, loadedOffset == offset {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(page.sources, id: \.application) { source in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    SourceApplicationLabel(application: source.application, store: sourceIcons)
                                    Spacer(minLength: 4)
                                    Text(PreviewCopy.copyCount(source.count, locale: locale))
                                        .foregroundStyle(.secondary)
                                }
                                CopyTimeRow(label: "Last Copied", date: source.lastCopiedAt)
                                if source.count > 1 {
                                    CopyTimeRow(label: "First Copied", date: source.firstCopiedAt)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 140)
                .id(offset)
                if offset > 0 || page.nextOffset != nil {
                    HStack {
                        Button(PreviewCopy.text("Previous Sources")) { offset = max(0, offset - 32) }
                            .disabled(offset == 0)
                        Spacer()
                        Button(PreviewCopy.text("More Sources")) {
                            if let next = page.nextOffset { offset = next }
                        }
                        .disabled(page.nextOffset == nil)
                    }
                    .buttonStyle(.plain)
                }
            } else if failed {
                Button(PreviewCopy.text("Retry Copy Information")) { retry += 1 }
                    .buttonStyle(.plain)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: Request(offset: offset, retry: retry)) {
            failed = false
            do {
                let value = try await history.copySources(
                    for: row.item.id, expectedCopyCount: row.copyCount, offset: offset
                )
                try Task.checkCancellation()
                guard value.item == row.item else {
                    failed = true
                    return
                }
                page = value
                loadedOffset = offset
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}

private struct CopyTimeRow: View {
    let label: String
    let date: Date
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(PreviewCopy.text(label)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(date, format: Date.FormatStyle(
                    date: .abbreviated, time: .omitted, locale: locale, timeZone: timeZone
                ))
                    .accessibilityIdentifier(label == "Last Copied" ? "clipy.preview.information.date" : "clipy.preview.first-date")
                Text(date, style: .time)
                    .accessibilityIdentifier(label == "Last Copied" ? "clipy.preview.information.time" : "clipy.preview.first-time")
            }
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
        }
        .help(date.formatted(Date.FormatStyle(
            date: .complete, time: .complete, locale: locale, timeZone: timeZone
        )))
    }
}

/// Resolution belongs to the visible application label, never to history
/// rows. Icons and names share the panel's bounded display cache (01 §8).
struct SourceApplicationLabel: View {
    let application: String?
    let store: SourceIconStore?
    var isInformation = false

    var body: some View {
        HStack(spacing: 5) {
            if let application, let icon = store?.cachedIcon(forBundleID: application) {
                Image(decorative: icon, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(application.map { store?.cachedName(forBundleID: $0) ?? $0 }
                ?? PreviewCopy.text("Unknown Application"))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier(isInformation ? "clipy.preview.information.source" : "clipy.preview.application")
        }
        .help(application ?? PreviewCopy.text("Unknown Application"))
        .onAppear { if let application { store?.setDisplayed(application, true) } }
        .onDisappear { if let application { store?.setDisplayed(application, false) } }
        .onChange(of: application) { old, new in
            if let old { store?.setDisplayed(old, false) }
            if let new { store?.setDisplayed(new, true) }
        }
        .onChange(of: store?.isPrefetchSuspended) { _, suspended in
            if suspended == false { resolve() }
        }
        .onChange(of: store?.isSurfaceActive) { _, active in
            if active == true { resolve() }
        }
        .task(id: application) {
            guard !Task.isCancelled else { return }
            resolve()
        }
    }

    private func resolve() {
        if let application { store?.icon(forBundleID: application) }
    }
}
