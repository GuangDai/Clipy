/// Progressive search controls: familiar dates/application filters first,
/// expression syntax and examples on demand. All query execution stays in
/// HistoryViewState/HistoryCore (03a §7; V2-07 §3).
import Foundation
import HistoryCore
import SwiftUI
import UniformTypeIdentifiers

struct HistorySearchOptionsView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    private let viewState: HistoryViewState
    private let suggestedSources: [String]
    @State private var draft: HistorySearchFilters
    @State private var draftSortOrder: HistorySortOrder
    @State private var showsExpressionGuide: Bool
    @State private var isChoosingApplication = false
    @State private var applicationSelectionFailed = false
    @State private var applications: [SourceApplicationSearchResolver.Application] = []

    init(viewState: HistoryViewState, suggestedSources: [String], showsExpressionGuide: Bool) {
        self.viewState = viewState
        self.suggestedSources = suggestedSources
        _draft = State(initialValue: viewState.searchFilters)
        _draftSortOrder = State(initialValue: viewState.sortOrder)
        _showsExpressionGuide = State(initialValue: showsExpressionGuide)
    }

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }
    private func text(_ value: String) -> String { HistorySearchCopy.text(value, bundle: copyBundle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("Search options")).font(.headline)
                Spacer()
                Button(text("Done")) { dismiss() }
                    .accessibilityIdentifier("clipy.search.options.done")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker(text("Sort results"), selection: $draftSortOrder) {
                        ForEach(HistorySortOrder.allCases, id: \.self) { order in
                            Text(HistorySearchCopy.sortTitle(order, bundle: copyBundle)).tag(order)
                        }
                    }
                    .accessibilityIdentifier("clipy.search.options.sort")
                    dateControls
                    Divider()
                    sourceControls
                    HStack {
                        Button(text("Reset")) {
                            draft = HistorySearchFilters()
                            draftSortOrder = .automatic
                        }
                        Spacer()
                        Button(text("Apply search options")) {
                            let changed = viewState.searchFilters != draft || viewState.sortOrder != draftSortOrder
                            viewState.searchFilters = draft
                            viewState.sortOrder = draftSortOrder
                            if !changed { viewState.refresh() }
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.hasValidDates())
                        .accessibilityIdentifier("clipy.search.options.apply")
                    }
                    Divider()
                    DisclosureGroup(text("Advanced expressions"), isExpanded: $showsExpressionGuide) {
                        expressionGuide.padding(.top, 8)
                    }
                    .accessibilityIdentifier("clipy.search.expression.guide")
                }
                .padding(.trailing, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 480)
        }
        .padding(16)
        .frame(width: 360)
        .accessibilityIdentifier("clipy.search.options")
        .task { applications = await viewState.searchSourceApplications() }
    }

    private var dateControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text("Copy date"), systemImage: "calendar").font(.subheadline.weight(.medium))
            Picker(text("Copy date"), selection: $draft.dateRange) {
                ForEach(HistorySearchDateRange.allCases, id: \.self) { range in
                    Text(text(range.title)).tag(range)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("clipy.search.date.range")
            if draft.dateRange == .custom {
                DatePicker(text("From"), selection: $draft.startDate, displayedComponents: .date)
                    .accessibilityIdentifier("clipy.search.date.from")
                DatePicker(text("Through"), selection: $draft.endDate, displayedComponents: .date)
                    .accessibilityIdentifier("clipy.search.date.through")
                if !draft.hasValidDates() {
                    Label(text("The end date must be on or after the start date."), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("clipy.search.date.error")
                }
            }
            Text(text("Uses the most recent copy date in your local time zone. Both selected dates are included."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text("Source application"), systemImage: "app.badge").font(.subheadline.weight(.medium))
            Picker(text("Match source by"), selection: $draft.sourceMatch) {
                Text(text("Application name")).tag(HistorySearchSourceMatch.applicationName)
                Text("Bundle ID").tag(HistorySearchSourceMatch.bundleIdentifier)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("clipy.search.source.match")
            TextField(text(draft.sourceMatch == .applicationName ? "Application name contains" : "Exact bundle identifier"),
                      text: $draft.sourceApplication,
                      prompt: Text(draft.sourceMatch == .applicationName ? "Telegram" : "com.apple.Safari"))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("clipy.search.source.field")
            HStack {
                if !suggestedSources.isEmpty {
                    Menu(text("From loaded history")) {
                        ForEach(suggestedSources, id: \.self) { source in
                            Button(sourceTitle(source)) {
                                draft.sourceApplication = source
                                draft.sourceMatch = .bundleIdentifier
                            }
                        }
                    }
                    .accessibilityIdentifier("clipy.search.source.suggestions")
                }
                if !applications.isEmpty {
                    Menu(text("Installed applications")) {
                        ForEach(applications) { application in
                            Button(application.displayName + " · " + application.bundleID) {
                                draft.sourceApplication = application.bundleID
                                draft.sourceMatch = .bundleIdentifier
                            }
                        }
                    }
                    .accessibilityIdentifier("clipy.search.source.installed")
                }
            }
            HStack {
                Button(text("Choose application…")) {
                    applicationSelectionFailed = false
                    isChoosingApplication = true
                }
                .accessibilityIdentifier("clipy.search.source.choose")
            }
            .controlSize(.small)
            .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications", isDirectory: true))
            .fileImporter(isPresented: $isChoosingApplication, allowedContentTypes: [.application]) { result in
                switch result {
                case .success(let url):
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    if let identifier = Bundle(url: url)?.bundleIdentifier {
                        draft.sourceApplication = identifier
                        draft.sourceMatch = .bundleIdentifier
                    } else {
                        applicationSelectionFailed = true
                    }
                case .failure:
                    applicationSelectionFailed = true
                }
            }
            if applicationSelectionFailed {
                Text(text("The application's identifier could not be read. Enter it above instead."))
                    .font(.caption).foregroundStyle(.red)
            }
            Text(text("Application names match installed apps by name, ignoring case. Bundle IDs match the latest source exactly, including apps no longer installed."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(text("For multiple applications, use an expression such as source:Telegram OR source:Brave."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var expressionGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let issue = HistorySearchCopy.issue(for: viewState, bundle: copyBundle) {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(text("Choose Expression in Search Mode to combine conditions. Regular search keeps its existing meaning."))
                .font(.caption).foregroundStyle(.secondary)
            syntaxRow("AND · OR · NOT", "Combine conditions; parentheses group them. NOT runs first, then AND, then OR.")
            syntaxRow("\"meeting notes\"", "Quotes keep a phrase together. Adjacent terms mean AND.")
            syntaxRow("source:Telegram", "Match an installed application's name, ignoring case. app: is also accepted.")
            syntaxRow("source-id:com.apple.Safari", "Match an exact source bundle identifier, including apps no longer installed.")
            syntaxRow("date:2026-09-26", "Find one UTC day, or a range such as date:2026-09-01..2026-09-26.")
            syntaxRow("after:2026-09-01 before:2026-10-01", "After includes that UTC day; before excludes that day.")
            syntaxRow("type:text · type:images · type:links · is:pinned", "Combine content type and pinned status with other conditions.")
            Text(text("Examples")).font(.subheadline.weight(.medium))
            example("source:Telegram OR source:Brave")
            example("(source:Telegram OR source:Brave) AND NOT type:images")
            example("\"meeting notes\" AND after:2026-09-01")
            Text(text("Using an example replaces the query and selects Expression mode. Date and application filters still apply."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func syntaxRow(_ syntax: String, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(syntax).font(.caption.monospaced()).textSelection(.enabled)
            Text(text(explanation)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sourceTitle(_ identifier: String) -> String {
        guard let app = applications.first(where: { $0.bundleID == identifier }) else { return identifier }
        return app.displayName + " · " + identifier
    }

    private func example(_ query: String) -> some View {
        Button {
            viewState.searchMode = .expression
            viewState.searchText = query
            dismiss()
        } label: {
            HStack(alignment: .top) {
                Text(query).font(.caption.monospaced()).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.left")
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: PanelTheme.cornerRadiusSmall))
        }
        .buttonStyle(.plain)
        .help(text("Use this expression"))
    }
}
