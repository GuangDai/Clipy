import Foundation
import HistoryCore
import SwiftUI

/// Visible rows prepare only file references and app names;
/// raster bytes and temporary files are deferred until the user clicks.
struct HistoryOpenMenu: View {
    let item: HistoryItemReference
    let opener: HistoryExternalOpener
    let onFailure: (HistoryOpenFailure) -> Void
    @Environment(\.locale) private var locale
    let options: [HistoryOpenOption]
    let isLoading: Bool
    let failure: HistoryOpenFailure?

    var body: some View {
        Group {
            if isLoading {
                Button(PanelActionsCopy.text("Open in Default Application", bundle: copyBundle)) {}
                    .disabled(true)
            } else if let failure {
                Button(PanelActionsCopy.text("Open in Default Application", bundle: copyBundle)) {
                    onFailure(failure)
                }
            } else {
                ForEach(options) { option in
                    Button {
                        Task {
                            do { try await opener.open(option) }
                            catch is CancellationError { }
                            catch { onFailure((error as? HistoryOpenFailure) ?? .unavailable) }
                        }
                    } label: {
                        Label(label(for: option), systemImage: "arrow.up.forward.app")
                    }
                    .help(option.imageExtension == nil ? "" : PanelActionsCopy.text(
                        "Opens a temporary copy. Changes are not saved to history. Copies older than 24 hours are removed when opening another image in a later session.",
                        bundle: copyBundle))
                }
            }
        }
    }

    private var copyBundle: Bundle { PanelActionsCopy.bundle(for: locale) }

    private func label(for option: HistoryOpenOption) -> String {
        if options.count > 1 {
            let name = option.file?.lastPathComponent
                ?? "\(option.request.pasteboardItemIndex + 1).\(option.imageExtension ?? "")"
            return String(format: PanelActionsCopy.text("Open %@ in %@", bundle: copyBundle), name, option.applicationName)
        }
        return PanelActionsCopy.format("Open in %@", option.applicationName, bundle: copyBundle)
    }
}
