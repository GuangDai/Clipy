import Foundation

/// A bounded page of distinct application identifiers observed anywhere in
/// retained copy occurrences. These reads never load content projections or
/// payloads. Unknown and empty observations do not identify an application.
public struct HistorySourceApplicationRequest: Sendable, Hashable {
    public let limit: Int
    public let cursor: HistorySourceApplicationCursor?

    public init(limit: Int = 32, cursor: HistorySourceApplicationCursor? = nil) {
        self.limit = limit
        self.cursor = cursor
    }
}

/// Opaque continuation of the same retained-History snapshot. A commit or a
/// different History instance expires it, rather than skipping/repeating IDs.
public struct HistorySourceApplicationCursor: Sendable, Hashable {
    package let position: ChangePosition
    package let processMarker: UUID
    package let afterApplication: String

    package init(position: ChangePosition, processMarker: UUID, afterApplication: String) {
        self.position = position
        self.processMarker = processMarker
        self.afterApplication = afterApplication
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.position == rhs.position && lhs.processMarker == rhs.processMarker
            && lhs.afterApplication.utf8.elementsEqual(rhs.afterApplication.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(position)
        hasher.combine(processMarker)
        hashSourceIdentifier(afterApplication, into: &hasher)
    }
}

public struct HistorySourceApplicationPage: Sendable, Hashable {
    public let position: ChangePosition
    /// Exact stored identifiers, in literal ascending order, each once.
    public let applications: [String]
    public let next: HistorySourceApplicationCursor?

    public init(position: ChangePosition, applications: [String], next: HistorySourceApplicationCursor? = nil) {
        self.position = position
        self.applications = applications
        self.next = next
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.position == rhs.position && lhs.next == rhs.next && lhs.applications.count == rhs.applications.count
            && zip(lhs.applications, rhs.applications).allSatisfy { pair in pair.0.utf8.elementsEqual(pair.1.utf8) }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(position)
        hasher.combine(next)
        hasher.combine(applications.count)
        for application in applications { hashSourceIdentifier(application, into: &hasher) }
    }
}

private func hashSourceIdentifier(_ value: String, into hasher: inout Hasher) {
    var value = value
    value.withUTF8 {
        hasher.combine($0.count)
        hasher.combine(bytes: UnsafeRawBufferPointer($0))
    }
}
