/// SourceIconStore.swift — bounded per-surface retention of source-app icons
/// shown in a row's leading slot while no thumbnail raster exists for it.
///
/// Same admission posture as `ThumbnailStore`'s bounded retention (see that
/// file's header): this is per-surface DISPLAY STATE — one store per browsing
/// surface, keyed by bundle identifier, released with its surface — not a
/// shared cross-surface icon cache.
import CoreGraphics
import Foundation
import SwiftUI

/// One browsing surface's source-icon retention. The injected
/// `SourceIconProvider` (the composition root's AppKit loader) is consulted
/// at most once per retained bundle ID; the result — including a negative
/// `nil` — is retained so rows do not re-ask until eviction. Retention is
/// bounded with FIFO eviction:
/// distinct source apps are few in practice, and the bound keeps a
/// long-lived panel from accumulating an unbounded set of decoded
/// application icons behind an adversarial bundle-ID stream.
@MainActor @Observable
package final class SourceIconStore {

    /// The retention bound. 64 distinct source applications is far beyond a
    /// realistic clipboard session, so ordinary use never evicts; the bound
    /// exists so the store cannot grow without limit.
    package static let maximumEntries = 64

    private let provider: SourceIconProvider

    /// One resolution's identity and optional icon. A nil icon both stops
    /// synchronous same-bundle reentry and retains a completed negative.
    /// Replacing the dictionary value publishes through Observation.
    private final class Entry {
        let icon: CGImage?

        init(icon: CGImage?) {
            self.icon = icon
        }
    }

    private var entries: [String: Entry] = [:]

    /// Insertion order for FIFO eviction (`entries` alone is unordered).
    private var insertionOrder: [String] = []

    package init(provider: SourceIconProvider) {
        self.provider = provider
    }

    /// The retained icon for one bundle ID, or `nil` when unresolved or
    /// recorded negative. A pure read for row bodies: view body evaluation
    /// must not mutate observable state, so provider resolution happens in
    /// the row's `.task` via `icon(forBundleID:)`.
    package func cachedIcon(forBundleID bundleID: String) -> CGImage? {
        entries[bundleID]?.icon
    }

    /// Resolves and retains the icon for one bundle ID, consulting the
    /// provider at most once per ID (negative results are retained too).
    /// Capacity eviction drops the oldest resolutions; a row whose icon was
    /// evicted simply re-resolves the next time its `.task` runs.
    @discardableResult
    package func icon(forBundleID bundleID: String) -> CGImage? {
        if let entry = entries[bundleID] { return entry.icon }
        // The provider may reenter this synchronous MainActor call. Record
        // the existing nil entry before invoking it so another row asking
        // for this bundle does not recursively load it a second time.
        let entry = Entry(icon: nil)
        entries[bundleID] = entry
        insertionOrder.append(bundleID)
        while entries.count > Self.maximumEntries {
            entries.removeValue(forKey: insertionOrder.removeFirst())
        }
        let resolved = provider.loadIcon(bundleID)
        // Nested loads may evict this entry and then resolve the same bundle
        // again. Only this resolution's own entry may accept its result.
        if entries[bundleID] === entry {
            entries[bundleID] = Entry(icon: resolved)
        }
        return resolved
    }
}
