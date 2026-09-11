import Foundation

/// Text-preview work and retention preferences. These affect only the inert
/// preview; stored clipboard content, copying and search are independent.
public struct PreviewTextConfiguration: Equatable, Sendable {
    /// The default amount retained for a preview. Callers can choose any
    /// positive count or nil for the complete decoded text; this is not a
    /// renderer hard limit. Source-format byte budgets still apply.
    public static let defaultMaximumCharacters = 50_000
    public let maximumCharacters: Int?

    /// UTF-16 units per lazily displayed segment. This bounds one text-view
    /// layout operation, not total document length. Smaller units improve
    /// first display and retargeting; larger units reduce segment overhead.
    /// Two units are the structural minimum for a complete Unicode scalar.
    public let segmentUTF16Budget: Int

    public init(
        maximumCharacters: Int? = Self.defaultMaximumCharacters,
        segmentUTF16Budget: Int = 1_024
    ) {
        self.maximumCharacters = maximumCharacters.map { max(1, $0) }
        self.segmentUTF16Budget = max(2, segmentUTF16Budget)
    }
}
