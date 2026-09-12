/// SourceIconStore.swift — bounded per-surface retention of source-app icons
/// shown beside application names in the expanded copy information.
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
/// bounded with FIFO eviction among non-displayed applications first:
/// distinct source apps are few in practice, and the bound keeps a
/// long-lived panel from accumulating an unbounded set of decoded
/// application icons behind an adversarial bundle-ID stream.
@MainActor @Observable
final class SourceIconStore {

    /// The retention bound. 64 distinct source applications is far beyond a
    /// realistic clipboard session, so ordinary use never evicts; the bound
    /// exists so the store cannot grow without limit.
    static let maximumEntries = 64

    private let provider: SourceIconProvider

    /// One resolution's identity and optional icon. A nil icon both stops
    /// synchronous same-bundle reentry and retains a completed negative.
    /// Replacing the dictionary value publishes through Observation.
    private final class Entry {
        let icon: CGImage?
        let name: String?

        init(icon: CGImage?, name: String? = nil) {
            self.icon = icon
            self.name = name
        }
    }

    private var entries: [String: Entry] = [:]

    /// Insertion order for FIFO eviction (`entries` alone is unordered).
    private var insertionOrder: [String] = []
    private var displayedBundleCounts: [String: Int] = [:]
    var isSurfaceActive = true
    private(set) var isPrefetchSuspended = false

    func setDisplayed(_ bundleID: String, _ displayed: Bool) {
        let count = (displayedBundleCounts[bundleID] ?? 0) + (displayed ? 1 : -1)
        displayedBundleCounts[bundleID] = count > 0 ? count : nil
        // Appearance can follow the view's task. A request declined while
        // every retained entry was visible now expresses actual display
        // demand and must get another chance without waiting for a new task.
        if displayed, entries[bundleID] == nil {
            icon(forBundleID: bundleID)
        }
    }

    func respondToMemoryPressure(_ pressure: DisplayMemoryPressure) {
        switch pressure {
        case .normal:
            isPrefetchSuspended = false
        case .warning:
            entries = entries.filter { isSurfaceActive && displayedBundleCounts[$0.key] != nil }
            insertionOrder.removeAll { entries[$0] == nil }
        case .critical:
            isPrefetchSuspended = true
            entries.removeAll()
            insertionOrder.removeAll()
        }
    }

    init(provider: SourceIconProvider) {
        self.provider = provider
    }

    /// The retained icon for one bundle ID, or `nil` when unresolved or
    /// recorded negative. A pure read for application-label bodies: view body evaluation
    /// must not mutate observable state, so provider resolution happens in
    /// the row's appearance or `.task` via `icon(forBundleID:)`.
    func cachedIcon(forBundleID bundleID: String) -> CGImage? {
        entries[bundleID]?.icon
    }

    func cachedName(forBundleID bundleID: String) -> String? {
        entries[bundleID]?.name
    }

    /// Resolves and retains the icon for one bundle ID, consulting the
    /// provider at most once per ID (negative results are retained too).
    /// Capacity eviction drops the oldest non-displayed resolutions first.
    /// A displayed label's task need not run again when another application
    /// resolves, so preserve its icon and readable name while cold entries
    /// can make room. If every entry is displayed, the hard bound still wins.
    @discardableResult
    func icon(forBundleID bundleID: String) -> CGImage? {
        if let entry = entries[bundleID] { return entry.icon }
        guard !isPrefetchSuspended, isSurfaceActive else { return nil }
        // The provider may reenter this synchronous MainActor call. Record
        // the existing nil entry before invoking it so another row asking
        // for this bundle does not recursively load it a second time.
        let entry = Entry(icon: nil)
        entries[bundleID] = entry
        insertionOrder.append(bundleID)
        while entries.count > Self.maximumEntries {
            let evictionIndex = insertionOrder.firstIndex {
                !isSurfaceActive || displayedBundleCounts[$0] == nil
            } ?? 0
            entries.removeValue(forKey: insertionOrder.remove(at: evictionIndex))
        }
        // All retained entries can already be displayed, making this new
        // cold request its own eviction victim. Do not invoke a provider
        // without the placeholder that prevents synchronous same-ID reentry.
        guard entries[bundleID] === entry else { return nil }
        let resolved = provider.loadIcon(bundleID)
        let name = provider.loadName(bundleID)
        // Nested loads may evict this entry and then resolve the same bundle
        // again. Only this resolution's own entry may accept its result.
        if entries[bundleID] === entry {
            entries[bundleID] = Entry(icon: resolved, name: name)
        }
        return resolved
    }
}
