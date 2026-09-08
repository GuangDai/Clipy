import SwiftUI

/// A disclosure whose complete visible heading is a native button. The
/// explicit container keeps its identity separate from the content controls.
struct AppDisclosureGroupStyle: DisclosureGroupStyle {
    let identifier: String
    let accessibilityLabel: String?

    init(identifier: String, accessibilityLabel: String? = nil) {
        self.identifier = identifier
        self.accessibilityLabel = accessibilityLabel
    }

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let accessibilityLabel {
                header(configuration: configuration)
                    .accessibilityLabel(Text(accessibilityLabel))
            } else {
                header(configuration: configuration)
            }
            if configuration.isExpanded {
                configuration.content
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func header(configuration: Configuration) -> some View {
        Button {
            configuration.isExpanded.toggle()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                configuration.label
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier + ".toggle")
        // DisclosureGroup supplies the native disclosure role and expanded
        // state. A custom visual Button does not replace those AX semantics.
    }
}
