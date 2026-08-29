/// CaptureIgnoreList.swift — the user-managed list of source applications
/// whose clipboard values are never recorded. Sensitive apps (password
/// managers, authenticators, banking apps) can be excluded from capture by
/// bundle identifier. This type is only the framework-neutral value the
/// Settings surface edits and persists: the enforcement gate itself is
/// applied by the ClipyApp composition root, which re-reads the persisted
/// list per capture event and refuses a captured value before it ever
/// reaches the history (01 §8 — the composition root owns the
/// pasteboard-side wiring; PresentationUI owns the value and its editing
/// surface).
import Foundation

/// The capture ignore list: the normalized (lowercase, sorted,
/// de-duplicated) bundle identifiers of the applications whose clipboard
/// contents must not enter the history.
///
/// Every entry point fails closed toward a clean list: loading sanitizes
/// persisted entries, and `add` reports — without mutating — any value
/// that is not a reverse-domain identifier, so a hand-edited defaults
/// value can never corrupt the gate.
public struct CaptureIgnoreList: Equatable, Sendable {

    /// The UserDefaults key carrying the persisted `[String]` of
    /// normalized bundle identifiers.
    public static let defaultsKey = "clipy.capture.ignoredBundleIDs"

    /// The normalized bundle identifiers: lowercase, sorted,
    /// de-duplicated. Package (GOV-3): only the in-package Settings editor
    /// reads the collection; ClipyApp consumes the list through `ignores(_:)`.
    package private(set) var bundleIDs: [String]

    /// Builds a list from raw entries; entries that fail validation are
    /// dropped rather than carried into the gate. Package (GOV-3): the
    /// composition root loads the value via `load(from:)`, never by naming
    /// entries.
    package init(bundleIDs: [String] = []) {
        self.bundleIDs = Self.normalized(bundleIDs)
    }

    /// Loads the persisted list; an absent key or a value that is not a
    /// string array reads as the empty list (the same per-key fail-open
    /// reading as `PanelAppearanceSettings.load(from:)`).
    public static func load(from defaults: UserDefaults) -> CaptureIgnoreList {
        CaptureIgnoreList(
            bundleIDs: defaults.stringArray(forKey: defaultsKey) ?? []
        )
    }

    /// Persists the normalized list under `defaultsKey`. Package (GOV-3):
    /// the Settings capture tab owns the editing-and-storing loop.
    package func store(to defaults: UserDefaults) {
        defaults.set(bundleIDs, forKey: Self.defaultsKey)
    }

    /// Whether a source application's bundle identifier is ignored.
    /// Matching is case-insensitive; `nil` (an unidentified source) is
    /// never ignored.
    public func ignores(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(Self.normalize(bundleID))
    }

    /// Adds one bundle identifier, returning whether the list changed.
    /// `false` — with the list unchanged — when the value is not a
    /// reverse-domain identifier (at least one dot; alphanumerics,
    /// hyphens, and dots only, compared after lowercase normalization) or
    /// is already listed. Package (GOV-3): Settings-editor intents only.
    package mutating func add(_ bundleID: String) -> Bool {
        let normalized = Self.normalize(bundleID)
        guard Self.isValid(normalized), !bundleIDs.contains(normalized) else {
            return false
        }
        bundleIDs.append(normalized)
        bundleIDs.sort()
        return true
    }

    /// Removes one bundle identifier (case-insensitive); removing an
    /// identifier that is not listed is a no-op. Package (GOV-3):
    /// Settings-editor intents only.
    package mutating func remove(_ bundleID: String) {
        bundleIDs.removeAll { $0 == Self.normalize(bundleID) }
    }

    /// Lowercase normalization with surrounding whitespace trimmed, so a
    /// pasted identifier and the persisted value always agree.
    private static func normalize(_ bundleID: String) -> String {
        bundleID
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    /// Reverse-domain shape: at least one dot, and nothing but ASCII
    /// alphanumerics, hyphens, and dots — the bundle-identifier character
    /// set, compared after normalization.
    private static func isValid(_ normalized: String) -> Bool {
        guard normalized.contains(".") else { return false }
        return normalized.allSatisfy { character in
            character == "." || character == "-"
                || (character.isASCII
                    && (character.isLetter || character.isNumber))
        }
    }

    /// Normalizes, validates, de-duplicates, and sorts raw entries.
    private static func normalized(_ rawBundleIDs: [String]) -> [String] {
        Array(
            Set(rawBundleIDs.map(Self.normalize).filter(Self.isValid))
        ).sorted()
    }
}
