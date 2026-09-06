/// App-owned, content-free history announcements. Native plural resources
/// use the same count wording as the panel without exposing clipboard data.
import Foundation

enum AppHistoryAnnouncementsCopy {
    static func text(_ english: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(
            forKey: english, value: english, table: "AppHistoryAnnouncements"
        )
    }

    static func searchResults(
        count: Int, hasNextPage: Bool,
        bundle: Bundle = .main, locale: Locale = .current
    ) -> String {
        let digits = count.formatted(.number.locale(locale))
        if hasNextPage {
            return String(
                format: text("%@+ results", bundle: bundle),
                locale: locale, arguments: [digits]
            )
        }
        let format = bundle.localizedString(
            forKey: "results",
            value: count == 1 ? "%2$@ result" : "%2$@ results",
            table: "AppHistoryAnnouncements"
        )
        // The numeric argument selects the resource's plural rule. The
        // second argument supplies regional digits and grouping verbatim.
        return String(format: format, locale: locale, arguments: [count, digits])
    }
}
