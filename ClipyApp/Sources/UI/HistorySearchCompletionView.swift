import SwiftUI

/// An in-window candidate list never becomes a second key window. Native
/// editing, selection and marked text remain owned by the search field.
struct HistorySearchCompletionView: View {
    let completion: HistorySearchCompletionState
    @Environment(\.locale) private var locale
    private var bundle: Bundle { PanelActionsCopy.bundle(for: locale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(completion.candidates) { candidate in
                            Button {
                                _ = completion.accept(id: candidate.id)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: candidate.id.hasPrefix("source.") ? "app" : "chevron.left.forwardslash.chevron.right")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.title).font(.callout).lineLimit(1)
                                        if let subtitle = candidate.subtitle {
                                            Text(verbatim: candidate.id.hasPrefix("source.") ? subtitle : text(subtitle))
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .background(isSelected(candidate.id) ? Color.accentColor.opacity(0.16) : .clear)
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .accessibilityIdentifier("clipy.search.completion." + candidate.id)
                            .accessibilityAddTraits(isSelected(candidate.id) ? .isSelected : [])
                            .id(candidate.id)
                        }
                        if completion.isLoadingSources {
                            ProgressView(text("Loading source applications…"))
                                .controlSize(.small).padding(9)
                        }
                        if completion.sourceFailure {
                            HStack {
                                Text(text("Source applications could not be loaded."))
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Button(text("Retry")) { _ = completion.command(.request) }
                                    .buttonStyle(.plain).focusable(false)
                            }.padding(9)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: completion.selectedIndex) { _, selected in
                    if completion.candidates.indices.contains(selected) {
                        proxy.scrollTo(completion.candidates[selected].id)
                    }
                }
            }
            Divider()
            Text(text("↑↓ Choose · Tab/Return Insert · Esc Dismiss"))
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: min(completion.availableHeight, Double(completion.candidates.count * 46 + 26 + (completion.isLoadingSources || completion.sourceFailure ? 40 : 0))))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)) }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("clipy.search.completions")
    }

    private func isSelected(_ id: String) -> Bool {
        completion.candidates.indices.contains(completion.selectedIndex)
            && completion.candidates[completion.selectedIndex].id.utf8.elementsEqual(id.utf8)
    }

    private func text(_ key: String) -> String { HistorySearchCopy.text(key, bundle: bundle) }
}
