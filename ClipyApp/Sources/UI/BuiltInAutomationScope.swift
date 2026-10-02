import Foundation

enum BuiltInAutomationTrigger: String, CaseIterable, Codable, Sendable {
    case manual, newCopies, both
    var title: String {
        switch self {
        case .manual: "Manual only"
        case .newCopies: "New copies automatically"
        case .both: "Manual and automatic"
        }
    }
    var includesAutomatic: Bool { self != .manual }
    var includesManual: Bool { self != .newCopies }
}

struct BuiltInAutomationScope: Codable, Equatable, Sendable {
    enum Source: String, CaseIterable, Codable, Sendable {
        case input, clipboard, history
        var title: String {
            switch self {
            case .input: "Provided text"
            case .clipboard: "Current clipboard"
            case .history: "History range"
            }
        }
    }
    enum TimeRange: String, CaseIterable, Codable, Sendable {
        case any, lastHour, today, lastWeek, custom
        var title: String {
            switch self {
            case .any: "Any time"
            case .lastHour: "Last hour"
            case .today: "Today"
            case .lastWeek: "Last 7 days"
            case .custom: "Custom dates"
            }
        }
    }
    var source: Source = .input
    var applications = ""
    var historyLimit = 100
    var timeRange: TimeRange = .any
    var startDate = Date(timeIntervalSinceReferenceDate: 0)
    var endDate = Date(timeIntervalSinceReferenceDate: 0)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.applications.utf8.elementsEqual(rhs.applications.utf8)
            && lhs.historyLimit == rhs.historyLimit && lhs.timeRange == rhs.timeRange
            && lhs.startDate == rhs.startDate && lhs.endDate == rhs.endDate
    }

    var validTimeRange: Bool {
        timeRange != .custom || (startDate <= endDate
            && startDate.timeIntervalSinceReferenceDate.isFinite && endDate.timeIntervalSinceReferenceDate.isFinite)
    }

    var applicationIDs: [String] {
        applications.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    func includes(application: String?, copiedAt: Date?, now: Date) -> Bool {
        includes(application: application, copiedAt: copiedAt, now: now,
                 allowedApplicationIDs: Set(applicationIDs))
    }

    /// A history range reuses this set instead of splitting the same filter
    /// and scanning every configured ID for each of its up to 1,000 rows.
    func includes(application: String?, copiedAt: Date?, now: Date,
                  allowedApplicationIDs: Set<String>) -> Bool {
        if !allowedApplicationIDs.isEmpty {
            guard let application, allowedApplicationIDs.contains(application.lowercased()) else { return false }
        }
        guard timeRange != .any else { return true }
        guard let copiedAt else { return false }
        switch timeRange {
        case .any: return true
        case .lastHour: return copiedAt >= now.addingTimeInterval(-3600) && copiedAt <= now
        case .today: return copiedAt >= Calendar.current.startOfDay(for: now) && copiedAt <= now
        case .lastWeek: return copiedAt >= now.addingTimeInterval(-7 * 86400) && copiedAt <= now
        case .custom: return copiedAt >= startDate && copiedAt <= endDate
        }
    }
}
